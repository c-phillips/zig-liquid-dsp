///! Zig build liquid-dsp 💦
///! 
///! This script replaces all of the autotools functions previously required to
///! build the project. Additionally, because Zig ships with its own everything
///! we can build the project for nearly *any native target*, including windows
///!
///! Its actually possible to use zig as a standalone compiler within existing
///! toolchains by doing something like `CC="zig cc" CXX="zig c++"`. However,
///! we can do extra stuff by writing a build program directly. For example,
///! all of the modules, tests, and benchmarks are discovered and compiled
///! together at build-time, so the build script can focus on building rather
///! than enumerating every necessary source file.
///!
///! To use this script, first download/install zig. Then, use one of the build
///! options (see all of them with `zig build -h`):
///!    `zig build lib`         Build the shared and static libraries
///!    `zig build example-all` Build all examples in `./examples`
///!    `zig build example-*`   Build and run any example in `./examples`
///!    `zig build test-all`    Build and run all package tests
///!    `zig build test-*`      Build and run any specific module's tests
///!
///! >[!note] Build steps are cached so a rebuild only happens after a change!
///!
///! Some additional options are:
///!    `-Dverbose-build`   Print additional information during build
///!    `-Dverbose-test`    Sets `liquid_test_verbose=1` in autotest
///!
///! You can also specify any build target with:
///!
///! >[!note] targeting the `MVCS` C ABI will not work since Microsoft has 
///! > decided to implement their very own version of `<complex.h>` 😊
///!
///! A good way to start is by running:
///! `zig build test-all --summary all`

const std = @import("std");
const builtin = @import("builtin");


/// Global build configuration type
const LiquidBuildOptions = struct {
    /// Print information like which modules are build built
    verbose_build: bool = false,
    /// Sets options inside the liquid autotest suite
    verbose_test: bool = false,
    /// Test with the shared library or statically linked one (tests are always static)
    link_shared: bool = false,
};
var LBO = LiquidBuildOptions{};


/// Removes both leading and trailing whitespace from the input string
pub fn trim(str: []const u8) []const u8{
    var start: usize = str.len-1;
    if( str.len == 0 ) return "";
    for(str, 0..) |c,i| {
        if( !std.ascii.isWhitespace(c) ){
            start = i;
            break;
        }
    }
    var end: usize = 0;
    var i = str.len-1;
    while(i > 0 and !std.ascii.isWhitespace(str[i])) : (i -= 1) {}
    end = i;
    return str[start..end+1];
}


/// Iterates through each item in the provided search path and gathers any
/// files with an extension that matches the one provided ("*" is wild)
pub fn getFilesByExtension(
    allocator: std.mem.Allocator,
    search_path: []const u8,
    comptime extension: []const u8, 
) !?[][]const u8 {
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var dir = std.fs.cwd().openDir( search_path, .{ .iterate = true } )
    catch |err| switch(err) {
        error.FileNotFound => return null,
        else => |e| return e
    };
    defer dir.close();
    
    var iter = dir.iterate();
    const wildcard: bool = std.mem.eql(u8, extension, "*");
    while (try iter.next()) |item| {
        if( item.kind == .file and (wildcard or std.mem.endsWith(u8, item.name, extension)) ){
            const item_path = try std.fs.path.join(
                allocator, &.{ search_path, item.name }
            );
            try files.append(item_path);
        }
    }

    return try files.toOwnedSlice();
}


const ModuleBuildOptions = struct {
    builder:  *std.Build,
    target:   std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags:    []const []const u8 = &.{},
    features: *const SIMDFeatures,
    includes: ?std.Build.LazyPath = null,
};
/// This allows us to easily collate modules for building, testing, and benchmarking
const Module = struct {
    path:          []const u8,
    name:          []const u8,
    src_path:      []const u8 = undefined,
    includes:      ?std.Build.LazyPath = null,
    builder:       *std.Build.Step.Run = undefined,
    test_builders: ?std.ArrayList(*std.Build.Step.Compile) = null,
    bench_builder: ?*std.Build.Step.Compile = null,

    /// Gathers together the module's source files, selecting the appropriate
    /// SIMD versions if available, and returns build-relative paths for each
    pub fn getRelSrcFiles(self: *Module, options: ModuleBuildOptions) ![]const []const u8 {
        const src_files: ?[][]const u8 = try getFilesByExtension(options.builder.allocator, self.src_path, ".c");
        if( src_files == null ) return error.NoSourceDir;

        var rel_src_files = std.ArrayList([]const u8).init(options.builder.allocator);
        defer rel_src_files.deinit();

        var rel_proto_files = std.ArrayList([]const u8).init(options.builder.allocator);
        defer rel_proto_files.deinit();

        var SIMD_extensions = std.StringHashMap(std.ArrayList([]const u8)).init(options.builder.allocator);
        defer {
            var values = SIMD_extensions.valueIterator();
            while(values.next()) |entry| {
                entry.deinit();
            }
            SIMD_extensions.deinit();
        }
        for(SIMDFeatures.extension_names) |extension| {
            try SIMD_extensions.put(extension, std.ArrayList([]const u8).init(options.builder.allocator));
        }
        var SIMD_compatible_src = std.StringHashMap(void).init(options.builder.allocator);
        defer SIMD_compatible_src.deinit();

        var has_SIMD:bool = false;
        for(src_files.?) |file| {
            const relpath = try std.fs.path.relative(
                options.builder.allocator, self.path, file
            );
            const filename = std.fs.path.stem(file);
            
            for(SIMDFeatures.extension_names) |extension| {
                if( std.mem.endsWith(u8, filename, extension) ) {
                    has_SIMD = true;
                    var list = SIMD_extensions.get(extension).?;
                    try list.append(relpath);
                    try SIMD_extensions.put(extension, list);
                    try SIMD_compatible_src.put(filename[0..(filename.len-extension.len)], {});
                }
            }
        }

        var SIMD_feature_files: ?std.ArrayList([]const u8) = null;
        if(has_SIMD){
            // TODO: add support for fallback SIMD modes
            if( options.features.using ) |feature|{
                SIMD_feature_files = SIMD_extensions.get(feature);
            }
        }
        if(SIMD_feature_files) |SIMD_src|{
            for(SIMD_src.items) |relpath| {
                try rel_src_files.append(relpath);
            }
        }

        file_iter: for(src_files.?) |file| {
            const relpath = try std.fs.path.relative(
                options.builder.allocator, self.path, file
            );
            
            const filename = std.fs.path.stem(relpath);
            if( std.mem.endsWith(u8, filename, ".proto") ) {
                try rel_proto_files.append(relpath);
            } else {
                if(has_SIMD){
                    var is_SIMD_src = false;
                    for(SIMDFeatures.extension_names) |extension| {
                        is_SIMD_src = is_SIMD_src or std.mem.endsWith(u8, filename, extension);
                        if( is_SIMD_src ) break;
                    }
                    if( is_SIMD_src ) continue :file_iter;  // we already appended the appropriate SIMD src earlier
                }
                if(SIMD_feature_files) |SIMD_src| {
                    var replace = false;
                    for(SIMD_src.items) |SIMD_file| {
                        const SIMD_replaces = std.fs.path.stem(std.fs.path.stem(SIMD_file));
                        replace = replace or std.mem.eql(u8, filename, SIMD_replaces);
                        if( replace ) break;
                    }
                    if( !replace ){
                        try rel_src_files.append(relpath);
                    }
                } else {
                    try rel_src_files.append(relpath);
                }
            }
        }
        if(SIMD_feature_files != null){
            if( LBO.verbose_build ) std.log.debug("\t\t-> Building {s} with {s} support", .{self.name, options.features.using.?});
            for(rel_src_files.items) |item| {
                if( LBO.verbose_build ) std.log.debug("\t\t\tUsing {s}", .{item});
            }
        }
        return try rel_src_files.toOwnedSlice();
    }

    pub fn new(path: []const u8, name: []const u8, options: ModuleBuildOptions) !*Module {
        var self  = try options.builder.allocator.create(Module);
        self.path = path;
        self.name = name;
        self.includes = options.includes;
        self.src_path = try std.fs.path.join(options.builder.allocator, &.{ self.path, "src" });

        // I'm not sure why its necessary to define this, but for whatever
        // reason, the compiler will not auto-initialize these when you
        // create the struct by allocating it like we did
        self.test_builders = null;
        self.bench_builder = null;

        if( LBO.verbose_build ) std.log.debug("Found module \"{s}\"", .{self.name});
        // ************************************************
        //      Build the src lib
        // ************************************************
        //TODO: Use this to generate static archives for linking manually into the main library
        //      that way we get the benefits of cached compilation for each module

        // const lib = options.builder.addStaticLibrary(.{
        //     .name = self.name,
        //     .target = options.target,
        //     .optimize = options.optimize,
        // });
        // lib.linkLibC();
        // if( self.includes != null ) lib.addIncludePath(self.includes.?);
        // lib.addIncludePath(.{.path = self.src_path});

        // const MOD_LIB_CFLAGS = try std.mem.concat(
        //     options.builder.allocator, 
        //     []const u8, &.{options.flags, &.{"-fwhole-program"}}
        // );
        // lib.addCSourceFiles(.{
        //     .root  = .{.path = self.path},
        //     .files = try self.getRelSrcFiles(options),
        //     .flags = MOD_LIB_CFLAGS
        // });

        // const module_install_step = options.builder.addInstallArtifact(lib, .{
        //     .dest_dir = .{ .override = std.Build.InstallDir{ .custom = "modules" } }
        // });
        // const ar_args = &.{
        //     "zig", "ar", "rcsv", options.builder.getInstallPath(module_install_step.dest_dir.?, try std.fmt.allocPrint(options.builder.allocator, "{s}.lib", .{self.name})),
        // };
        // const ar_step = options.builder.addSystemCommand(ar_args);
        // ar_step.step.dependOn(&module_install_step.step);
        // self.builder = ar_step;

        // ************************************************
        //      Find and build the test libs
        // ************************************************
        const test_path = try std.fs.path.join(options.builder.allocator, &.{ self.path, "tests" });
        const test_files: ?[][]const u8 = try getFilesByExtension(options.builder.allocator, test_path, ".c");

        if( test_files != null ){
            self.test_builders = std.ArrayList(*std.Build.Step.Compile).init(options.builder.allocator);

            var core_test_files = std.ArrayList([]const u8).init(options.builder.allocator);
            defer core_test_files.deinit();
            var supplementary_test_files = std.ArrayList([]const u8).init(options.builder.allocator);
            defer supplementary_test_files.deinit();
            for(test_files.?) |file| {
                if( !std.mem.endsWith(u8, std.fs.path.stem(file), "_autotest") ){
                    try supplementary_test_files.append(
                        try std.fs.path.relative( options.builder.allocator, self.path, file )
                    );
                } else {
                    try core_test_files.append(file);
                }
            }

            const data_path = try std.fs.path.join(options.builder.allocator, &.{test_path, "data"});
            var has_extra_data = true;
            std.fs.accessAbsolute(data_path, .{}) catch |err| switch(err) {
                error.FileNotFound => has_extra_data = false,
                else => return err
            };
            var data_objs = std.ArrayList(*std.Build.Step.Compile).init(options.builder.allocator);
            if( has_extra_data ){
                const data_src = try getFilesByExtension(options.builder.allocator, data_path, ".c");
                if(data_src) |files| {
                    var rel_data_files = std.ArrayList([]const u8).init(options.builder.allocator);
                    for(files) |file| {
                        try rel_data_files.append(try std.fs.path.relative(options.builder.allocator, data_path, file));
                    }
                    const data_obj = options.builder.addStaticLibrary(.{
                        .name = try std.mem.join(options.builder.allocator, "_", &.{self.name, "data"}),
                        .target = options.target,
                        .optimize = options.optimize,
                    });
                    data_obj.addCSourceFiles(.{
                        .root = .{.path = data_path},
                        .files = try rel_data_files.toOwnedSlice(),
                        .flags = options.flags,
                    });
                    data_obj.linkLibC();
                    if( self.includes != null ) data_obj.addIncludePath(self.includes.?);
                    data_obj.addIncludePath(.{.path = test_path});
                    try data_objs.append(data_obj);
                }
            }

            for(core_test_files.items) |test_file|{
                const test_name = try std.mem.concat(
                    options.builder.allocator,
                    u8, &.{ self.name,"_", std.fs.path.stem(test_file) }
                );

                // parse the test source file and find the test names
                const test_names = try Module.getTestSymbols(
                    options.builder.allocator,
                    test_file//options.builder.pathJoin(&.{self.path, test_file})
                );
                if( test_names == null ){
                    std.log.warn("Found a test file but no definitions for {s}::{s}", .{self.name, test_name});
                    continue;
                }

                // We need a way for the zig test to find the appropriate test symbols
                const zig_test_header = try self.generateTestHeader(options.builder.allocator, test_name, test_names.?);
                
                // This is where our zig test C header lives
                const tmp_test_path = try std.fs.path.relative(
                    options.builder.allocator,
                    options.builder.path(".").getPath(options.builder),
                    zig_test_header
                );

                // Generate the zig test file and create a build-test object
                const zig_test_path = try self.generateZigTests(options.builder.allocator, test_name, test_names.?);
                const test_exe = options.builder.addTest(.{
                    .name = test_name,
                    .target = options.target,
                    .optimize = options.optimize,
                    .root_source_file = .{.path = zig_test_path},
                });

                // Naturally, we need to link libc and libliquid
                test_exe.linkLibC();
                if( LBO.link_shared ){
                    test_exe.addLibraryPath(options.builder.path("./zig-out/lib/"));
                    test_exe.linkSystemLibrary("liquid");
                } else {
                    test_exe.addObjectFile(options.builder.path("./zig-out/lib/libliquid.lib"));
                }

                if( self.includes != null ) test_exe.addIncludePath(self.includes.?);
                test_exe.addIncludePath(.{ .path = "./autotest/" }); // contains all the necessary autotest symbols
                test_exe.addIncludePath(.{ .path = tmp_test_path }); // to include the C header for the zig test
                test_exe.addIncludePath(.{ .path = test_path});      // to include any other test headers
                test_exe.addIncludePath(options.builder.path("."));  // some tests require included headers from root?

                test_exe.addCSourceFile(.{ .file = .{.path = "./autotest/autotest.c"}, .flags = options.flags });
                test_exe.addCSourceFile(.{ .file = .{.path = test_file}, .flags = options.flags});
                test_exe.addCSourceFiles(.{
                    .root = .{.path = self.path},
                    .files = supplementary_test_files.items,
                    .flags = options.flags
                });

                if(data_objs.items.len > 0){
                    for(data_objs.items) |data| {
                        test_exe.linkLibrary(data);
                    }
                }
                
                test_exe.test_server_mode = false;

                if( LBO.verbose_build ) std.log.debug("\t\t+ Created test builder for module {s}::{s}", .{self.name, test_name});
                try self.test_builders.?.append(test_exe);
            }
        }

        // ************************************************
        //      Find and build the bench libs
        // ************************************************
        // TODO...

        return self;
    }

    /// Creates a C header file for importing into the Zig test file itself
    /// Basically just imports liquid, autotest, and enumerates the test funcs
    fn generateTestHeader(self: *Module, alloc: std.mem.Allocator, test_name: []const u8, func_names: [][]const u8) ![]const u8 {
        const dirname  = try std.fmt.allocPrint(alloc, "./zig-tests/{s}", .{self.name});
        const test_dir = try std.fs.cwd().makeOpenPath(dirname, .{});

        const file = try test_dir.createFile(
            try std.fmt.allocPrint(alloc, "{s}.h", .{test_name}),
            .{}
        );
        defer file.close(); // always be closing

        try file.writer().print(
        \\#include "liquid.h"
        \\#include "autotest/autotest.h"
        \\
        ,.{});

        for(func_names) |name| {
            if( !std.mem.endsWith(u8, name, "_config")){
                try file.writer().print(
                \\
                \\void {s}();
                \\
                ,.{name});
            }
        }

        return test_dir.realpathAlloc(alloc, ".");
    }

    /// Creates the Zig test file and includes the test-specific header
    fn generateZigTests(self: *Module, alloc: std.mem.Allocator, test_name: []const u8, func_names: [][]const u8) ![]const u8 {
        const dirname  = try std.fmt.allocPrint(alloc, "./zig-tests/{s}", .{self.name});
        const test_dir = try std.fs.cwd().makeOpenPath(dirname, .{});

        const filename = try std.fmt.allocPrint(alloc, "{s}.zig", .{test_name});
        const file = try test_dir.createFile(filename, .{});
        defer file.close();

        try file.writer().print(
        \\const std = @import("std");
        \\const c = @cImport({{
        \\  @cInclude("liquid.h");
        \\  @cInclude("autotest/autotest.h");
        \\  @cInclude("{s}.h");
        \\}});
        ,.{test_name});

        for(func_names) |name| {
            if( !std.mem.endsWith(u8, name, "_config")){
                try file.writer().print(
                \\
                \\test "{s}::{s}::{s}" {{
                \\  c.liquid_autotest_verbose = {d};
                \\  const initial_failed = c.liquid_autotest_num_failed;
                \\  c.{s}();
                \\  const post_failed = c.liquid_autotest_num_failed;
                \\  try std.testing.expect( initial_failed == post_failed );
                \\}}
                \\
                ,.{self.name, test_name, name, @intFromBool(LBO.verbose_test), name});
            }
        }

        return std.fs.path.join(alloc, &.{dirname, filename});
    }

    /// Parses a file and returns the functions that start with either
    /// `autotest` or `xautotest` for inclusion in our Zig test
    fn getTestSymbols(alloc: std.mem.Allocator, src_path: []const u8) !?[][]const u8 {
        const file = std.fs.cwd().openFile(src_path, .{}) catch unreachable;
        defer file.close();

        // We require a sentinel terminated buffer for the tokenizer
        var buffer = try alloc.allocSentinel(u8, (try file.stat()).size, 0);
        _ = try file.readAll(buffer);

        var func_names = std.ArrayList([]const u8).init(alloc);
        defer func_names.deinit();

        // Zig provides a nice little Tokenizer that is suitable for our needs
        var tokenizer = std.zig.Tokenizer.init(buffer);
        
        // FIXME: this is a segfault waiting to happen in case a `(` exists without
        //        an adjacent identifier for some reason
        var prev_token_loc: std.zig.Token.Loc = undefined; 
        while (true) {
            const token = tokenizer.next();
            switch (token.tag) {
                .eof => break,
                .identifier => {
                    prev_token_loc = token.loc;
                },
                .l_paren => {
                    if (prev_token_loc.start != prev_token_loc.end) {
                        const func_name = buffer[prev_token_loc.start..prev_token_loc.end];
                        if( std.mem.startsWith(u8, func_name, "autotest")
                            or std.mem.startsWith(u8, func_name, "xautotest")
                        ){
                            try func_names.append(func_name);
                        }
                    }
                },
                else => {},
            }
        }

        return if( func_names.items.len > 0 ) try func_names.toOwnedSlice() else null;
    }
};


/// An interface to the build-target CPU's SIMD features
const SIMDFeatures = struct {
    sse: bool = false,
    sse2: bool = false,
    sse3: bool = false,
    ssse3: bool = false,
    sse4_1: bool = false,
    sse4_2: bool = false,

    av: bool = false,
    avx: bool = false,
    avx2: bool = false,
    avx512f: bool = false,

    neon: bool = false,

    using: ?[]const u8 = null,
    compiler_flags: []const []const u8 = undefined,
    
    // These are the SIMD extension file identifiers for Liquid specifically
    // Files are named accordingly:
    //     Using ${SIMD} features:      `myfeature.${SIMD}.c`
    //     Portable non-SIMD version:   `myfeature.c`
    pub const extension_names: []const []const u8 = &.{".av", ".avx", ".avx512f", ".neon", ".sse"};
    
    /// To get the build-target feature set, create an object with `init`
    pub fn init(target: std.Build.ResolvedTarget) SIMDFeatures{
        var features = SIMDFeatures{};

        // to actually get the build-target cpu's features, we need to gather
        // the potential features, then actually populate them
        const cpu = target.result.cpu;
        var populated_features = cpu.features;
        populated_features.populateDependencies(cpu.arch.allFeaturesList());

        for(cpu.arch.allFeaturesList()) |feature|{
            // Uncomment this line if you're curious to see all the listed available features on your CPU
            // std.log.debug("Feature: {s} = {} : {s}", .{feature.name, populated_features.isEnabled(feature.index), feature.description});

            // TODO: make this a comptime generated function
            if     ( std.mem.eql(u8, feature.name, "sse"    ) ){ features.sse     = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "sse2"   ) ){ features.sse2    = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "sse3"   ) ){ features.sse3    = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "ssse3"  ) ){ features.sse3    = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "sse4_1" ) ){ features.sse4_1  = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "sse4_2" ) ){ features.sse4_2  = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "av"     ) ){ features.av      = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "avx"    ) ){ features.avx     = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "avx2"   ) ){ features.avx2    = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "avx512f") ){ features.avx512f = populated_features.isEnabled(feature.index); }
            else if( std.mem.eql(u8, feature.name, "neon"   ) ){ features.neon    = populated_features.isEnabled(feature.index); }
            else{ continue; }
        }
        features.compiler_flags = SIMDFeatures.setCompilerFlags(&features, target);
        
        return features;
    }

    pub fn hasSIMD(self: SIMDFeatures) bool {
        return self.hasSSE() or self.hasAVX() or self.neon;
    }
    pub fn hasSSE(self: SIMDFeatures) bool{
        return (self.sse or self.sse2 or self.sse3 or self.ssse3 or self.sse4_1 or self.sse4_2);
    }
    pub fn hasAVX(self: SIMDFeatures) bool{
        return (self.avx or self.avx2 or self.avx512f);
    }

    /// A private method to determine which compiler flags should be included
    /// using the found build-target features
    fn setCompilerFlags(self: *SIMDFeatures, target: std.Build.ResolvedTarget) []const []const u8 {
        if( self.hasSIMD() ){
            if( self.avx512f ) {
                self.using = ".avx512f";
                return &.{"-mavx512f"};
            } else if( self.hasAVX() ){
                self.using = ".avx";
                if( self.avx2 ) return &.{"-mavx2"};
                if( self.avx  ) return &.{"-mavx"};
                if( self.av   ) return &.{"-fno-common", "-faltivec"};
            } else if( self.hasSSE() and !self.neon  and !self.sse){
                self.using = ".sse";
                if( self.sse4_2 ) return &.{"-msse4.1"};
                if( self.sse4_1 ) return &.{"-msse4.1"};
                if( self.sse3   ) return &.{"-msse3"};
                if( self.sse2   ) return &.{"-msse2"};
            } else if( self.neon ){
                self.using = ".neon";
                if( !target.result.os.tag.isDarwin() ){
                    return &.{"-ffast-math", "-mfloat-abi=softfp", "-mfpu=neon"};
                }
                return &.{"-ffast-math"};
            } else {
                // TODO: Handle the non-neon arm version cases, of which there are many...
                return &.{""};
            }
        }
        return &.{""};
    }

};


const GeneratedCConfigOptions = struct {
    builder: *std.Build,
    target: *const std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    include_path: std.Build.LazyPath,
    features: *const SIMDFeatures,
};
/// Replaces the autoconfig tool and treats the `scripts/config.h` file like
/// a template. Writes the file into the project's `include` directory.
pub fn generateLiquidConfig(opts: GeneratedCConfigOptions) !void {
    const include_dir = try std.fs.openDirAbsolute(opts.include_path.getPath(opts.builder), .{});
    var exists = false;
    include_dir.access("config.h", .{}) catch |err| switch(err){
        error.FileNotFound => exists = true,
        else => return err
    };
    if(exists) try include_dir.deleteFile("config.h");

    const config_file = try include_dir.createFile("config.h", .{});
    defer config_file.close();

    const default_file = try std.fs.cwd().openFile("scripts/config.h", .{});
    const default_buf = try default_file.readToEndAlloc(opts.builder.allocator, (try default_file.stat()).size);

    var default_lines = std.ArrayList([]const u8).init(opts.builder.allocator);
    defer default_lines.deinit();
    var start: usize = 0;
    for(default_buf, 0..) |c, i| {
        if( c == '\n' ) {
            try default_lines.append(trim(default_buf[start..i]));
            start = i+1;
        }
    }

    var defines = std.StringHashMap([]const u8).init(opts.builder.allocator);
    defer defines.deinit();
    for(default_lines.items) |line| {
        if( std.mem.startsWith(u8, line, "#define") and !std.mem.endsWith(u8, line, "*/") ){
            var items = std.mem.splitSequence(u8, line, " ");
            _ = items.next();
            const name: []const u8 = items.next().?;
            
            if( !std.mem.startsWith(u8, name, "__") ) try defines.put(name, items.rest());
        }
    }

    if(opts.features.hasSIMD()){
        if( opts.features.hasAVX() ) try defines.put("HAVE_AVX", "1");
        if( opts.features.sse      ) try defines.put("HAVE_SSE", "1");
        if( opts.features.sse2     ) try defines.put("HAVE_SSE2", "1");
        if( opts.features.sse3     ) try defines.put("HAVE_SSE3", "1");
        if( opts.features.sse4_1   ) try defines.put("HAVE_SSE41", "1");
        if( opts.features.sse4_2   ) try defines.put("HAVE_SSE42", "1");
    }

    try config_file.writer().print(
    \\
    \\/* config.h.  Generated from config.h.in by configure.  */
    \\/* config.h.in.  Generated from configure.ac by autoheader.  */
    \\/* This is the default config.h to be included without running bootstrap and configure */
    \\
    \\#ifndef __LIQUID_CONFIG_H__
    \\#define __LIQUID_CONFIG_H__
    \\
    , .{});

    var it = defines.keyIterator();
    while(it.next()) |entry| {
        try config_file.writer().print(
        \\
        \\#define {s} {s}
        \\
        , .{entry.*, defines.get(entry.*).?});
    }

    try config_file.writer().print(
    \\
    \\#endif // __LIQUID_CONFIG_H__
    \\
    , .{});
}


pub fn build(b: *std.Build) !void {

    LBO.verbose_build = b.option(
        bool, "verbose-build",
        "Print extra information during the build process"
    ) orelse false;
    LBO.verbose_test  = b.option(
        bool, "verbose-test",
        "Set liquid-tests to verbose mode to see stdout+stderr from test programs"
    ) orelse false;
    LBO.link_shared   = b.option(
        bool, "link-shared",
        "Link against the shared library instead of the static library for tests/examples/etc."
    ) orelse false;

    const target   = b.standardTargetOptions(.{});
    const mode     = std.builtin.OptimizeMode.ReleaseFast;//b.standardOptimizeOption(.{.preferred_optimize_mode = .ReleaseFast});
    const features = SIMDFeatures.init(target);
    const includes = b.path("include");

    // TODO: determine the best set of flags; generally copied from makefile.in
    // NOTE: This has been very tricky to get right so far...
    // NOTE: Some additional options are set later, these are generic
    const default_CFLAGS = [_][]const u8{
        // "-O2", // set by default with .ReleaseFast
        "-Wall",
        "-Wno-deprecated",
        "-Wno-deprecated-declarations",
    };
    const CFLAGS = try std.mem.concat(
        b.allocator, 
        []const u8, &.{&default_CFLAGS, features.compiler_flags}
    );

    // We need to generate the project config header before we try to build
    try generateLiquidConfig(.{
        .builder      = b,
        .target       = &target,
        .optimize     = mode,
        .include_path = b.path("include"),
        .features     = &features
    });

    var src_dir = try std.fs.cwd().openDir("./src", .{.iterate=true});
    defer src_dir.close();

    const src_path = try std.fs.cwd().realpathAlloc(b.allocator, "src");

    // Gather all the project's submodules together and initialize their
    // respective sub-builders
    var modules = std.ArrayList(*Module).init(b.allocator);
    defer modules.deinit();

    const build_options = ModuleBuildOptions{
        .builder  = b,
        .target   = target,
        .optimize = mode,
        .flags    = CFLAGS,
        .features = &features,
        .includes = includes
    };

    var iter = src_dir.iterate();
    while( try iter.next() ) |entry| {
        if( entry.kind == .directory ){
            const module_path = try std.fs.path.join(b.allocator, &.{ src_path, entry.name });

            const module = try Module.new(
                module_path,
                try b.allocator.dupe(u8, entry.name),
                build_options
            );

            try modules.append(module);
        }
    }



    // ************************************************************************
    //      Build the liquid-dsp library objects
    // ************************************************************************
    if(LBO.verbose_build) std.log.debug("Building static archive...", .{});
    const liquid_ar = b.addStaticLibrary(.{
        .name = "libliquid",
        .target = target,
        .optimize = mode,
    });

    liquid_ar.linkLibC();
    liquid_ar.addIncludePath(includes);

    const AR_CFLAGS = try std.mem.concat(
        b.allocator, 
        []const u8, &.{CFLAGS, &.{"-fwhole-program"}}
    );
    liquid_ar.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"libliquid.c"},
        .flags = AR_CFLAGS
    });

    for(modules.items) |module| {
        liquid_ar.addIncludePath(.{.path = module.src_path});
        liquid_ar.addCSourceFiles(.{
            .root = .{.path = module.path},
            .files = try module.getRelSrcFiles(build_options),
            .flags = CFLAGS,
        });
    }

    const liquid_ar_install_step = b.addInstallArtifact(liquid_ar, .{});
    if( LBO.verbose_build ) std.log.debug("\t\tCreated builder for libliquid archive", .{});



    if( LBO.verbose_build ) std.log.debug("Building shared library...", .{});
    const liquid_sh = b.addSharedLibrary(.{
        .name = "liquid",
        .target = target,
        .optimize = mode,
    });

    // Trying to find a set of parameters that will avoid the windows issue...
    liquid_sh.linker_allow_shlib_undefined = true;
    liquid_sh.bundle_compiler_rt = true;   
    liquid_sh.link_function_sections = false;
    liquid_sh.link_gc_sections = false;
    liquid_sh.dll_export_fns = true;
    
    liquid_sh.linkLibC();
    liquid_sh.addIncludePath(includes);
    const SH_CFLAGS = try std.mem.concat(
        b.allocator, 
        []const u8, &.{CFLAGS, &.{"-fPIC", "-fwhole-program"}}
    );
    liquid_sh.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"libliquid.c"},
        .flags = SH_CFLAGS
    });

    for(modules.items) |module| {
        liquid_sh.addIncludePath(.{.path = module.src_path});
        liquid_sh.addCSourceFiles(.{
            .root = .{.path = module.path},
            .files = try module.getRelSrcFiles(build_options),
            .flags = CFLAGS,
        });
    }

    const liquid_sh_install_step = b.addInstallArtifact(liquid_sh, .{});
    if( LBO.verbose_build ) std.log.debug("\t\tCreated builder for libliquid shared", .{});


    const lib_step = b.step("lib", "Build libliquid");
    lib_step.dependOn(&liquid_ar_install_step.step);
    lib_step.dependOn(&liquid_sh_install_step.step);



    // ************************************************************************
    //      Build the example programs
    // ************************************************************************
    const examples_path = try std.fs.cwd().realpathAlloc(b.allocator, "examples");
    const example_files = try getFilesByExtension(b.allocator, examples_path, ".c");
    if( example_files == null ) return error.NoExamples;

    const example_step = b.step("example-all", "Build the example programs");
    example_step.dependOn(lib_step);

    try std.fs.cwd().makePath("zig-out/examples");

    var rel_example_files = std.ArrayList([]const u8).init(b.allocator);
    defer rel_example_files.deinit();
    for(example_files.?) |file| {
        const relpath = try std.fs.path.relative(
            b.allocator,
            try std.fs.cwd().realpathAlloc(b.allocator, "."),
            file
        );
        try rel_example_files.append(relpath);
    }

    var example_program_steps = std.StringHashMap(*std.Build.Step.InstallArtifact).init(b.allocator);
    defer example_program_steps.deinit();

    for( rel_example_files.items ) |filepath| {
        const example_name = try std.fmt.allocPrint(b.allocator, "example-{s}", .{std.fs.path.stem(filepath)});

        const example_exe = b.addExecutable(.{
            .name = example_name,
            .target = target,
            .optimize = mode,
        });
        example_exe.step.dependOn(lib_step);

        example_exe.linkLibC();
        example_exe.addIncludePath(includes);

        example_exe.addCSourceFiles(.{
            .files = &.{filepath},
            .flags = CFLAGS,
        });

        if( LBO.link_shared ){
            // Colocate the dynamic library with the examples
            const copy_lib = b.addInstallFile(
                b.path("./zig-out/lib/liquid.lib"),
                try std.fs.path.relative(b.allocator, ".", b.path("examples/liquid.lib").getPath(b))
            );
            const copy_dll = b.addInstallFile(
                b.path("./zig-out/lib/liquid.dll"),
                try std.fs.path.relative(b.allocator, ".", b.path("examples/liquid.dll").getPath(b))
            );
            example_exe.step.dependOn(&copy_lib.step);
            example_exe.step.dependOn(&copy_dll.step);
            example_exe.addLibraryPath(b.path("./zig-out/lib/"));
            example_exe.linkSystemLibrary("liquid");
        } else {
            example_exe.addObjectFile(b.path("./zig-out/lib/libliquid.lib"));
        }

        var example_install = b.addInstallArtifact(
            example_exe, 
            .{ .dest_dir = .{
                .override = std.Build.InstallDir{ .custom = "examples" }
            }}
        );
        example_step.dependOn(&example_install.step);
        
        try example_program_steps.put(example_name, example_install);
        const run_example_step = b.step(example_name[0..example_name.len-8], "Build and run this example program");
        const run_example_artifact = b.addRunArtifact(example_exe);
        run_example_artifact.step.dependOn(&example_install.step);
        run_example_step.dependOn(&run_example_artifact.step);
    }



    // ************************************************************************
    //      Build and run the tests
    // ************************************************************************
    const test_step = b.step("test-all", "Build and run all tests");
    test_step.dependOn(lib_step);

    if( LBO.verbose_build ) std.log.debug("Generating module test steps", .{});
    for(modules.items) |module| {
        if( module.*.test_builders ) |test_builders| {
            if( LBO.verbose_build ) std.log.debug("\t -> Adding {d} tests for {s}", .{test_builders.items.len, module.name});

            const step_name = try std.fmt.allocPrint(b.allocator, "test-{s}", .{module.name});
            const step_desc = try std.fmt.allocPrint(b.allocator, "Build and run tests for liquid-{s}", .{module.name});
            const module_test_step = b.step(step_name, step_desc);

            for(test_builders.items) |test_builder| {
                if( LBO.verbose_build ) std.log.debug("\t\t + Test: {s}", .{test_builder.name});

                test_builder.step.dependOn(lib_step);

                const run_test_cmd = b.addRunArtifact(test_builder);
                module_test_step.dependOn(&run_test_cmd.step);
                test_step.dependOn(&run_test_cmd.step);
            }
        } else {
            if( LBO.verbose_build ) std.log.debug("No tests found for {s}", .{module.name});
        }
    }
}
