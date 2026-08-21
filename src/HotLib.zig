const std = @import("std");
const builtin = @import("builtin");
const DynLib = std.DynLib;

pub fn HotLib(comptime Api: type) type {
    return struct {
        const Self = @This();

        api: Api,
        dynlib: DynLib,
        retired: std.ArrayList(DynLib),
        gpa: std.mem.Allocator,
        mtime: std.Io.Timestamp,
        dir_path: []const u8,
        source_name: []const u8,
        copy_id: u64,

        pub fn init(comptime library_name: []const u8, gpa: std.mem.Allocator, io: std.Io) !Self {
            const source_name = "lib" ++ library_name ++ ".so";
            const search_paths: []const [:0]const u8 = &.{
                "zig-out/lib/",
                "./",
            };
            const found_path: []const u8 = for (search_paths) |path| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, source_name }) catch continue;
                if (fileExists(full_path)) break path;
            } else return error.NoLibraryPathFound;

            var self: Self = .{
                .api = undefined,
                .dynlib = undefined,
                .retired = .empty,
                .gpa = gpa,
                .mtime = .zero,
                .dir_path = found_path,
                .source_name = source_name,
                .copy_id = 0,
            };
            self.dynlib, self.api, self.mtime = try self.open(io);
            return self;
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            _ = io;
            for (self.retired.items) |*old| old.close();
            self.retired.deinit(self.gpa);
            self.dynlib.close();
        }

        pub fn changed(self: *const Self, io: std.Io) bool {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const source_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ self.dir_path, self.source_name }) catch return false;
            const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch return false;
            return stat.mtime.nanoseconds > self.mtime.nanoseconds;
        }

        pub fn trySwap(self: *Self, io: std.Io) void {
            if (!self.changed(io)) return;

            const next_dynlib, const next_api, const next_mtime = self.open(io) catch |err| {
                std.log.err("{s}: reload failed, keeping the running build: {t}", .{ self.source_name, err });
                return;
            };

            self.retired.append(self.gpa, self.dynlib) catch {};
            self.dynlib = next_dynlib;
            self.api = next_api;
            self.mtime = next_mtime;
            std.log.info("reloaded {s}", .{self.source_name});
        }

        fn open(self: *Self, io: std.Io) !struct { DynLib, Api, std.Io.Timestamp } {
            var source_buf: [std.fs.max_path_bytes]u8 = undefined;
            const source_path = try std.fmt.bufPrint(&source_buf, "{s}{s}", .{ self.dir_path, self.source_name });
            const stat = try std.Io.Dir.cwd().statFile(io, source_path, .{});

            if (self.copy_id == 0) self.copy_id = @intCast(@mod(std.Io.Timestamp.zero.durationTo(.now(io, .real)).nanoseconds, 1_000_000_000));
            self.copy_id += 1;
            var copy_buf: [std.fs.max_path_bytes]u8 = undefined;
            const copy_path = try std.fmt.bufPrint(&copy_buf, "/tmp/{s}.{d}", .{ self.source_name, self.copy_id });

            try copyFile(source_path, copy_path, io);

            var dynlib = DynLib.open(copy_path) catch |err| {
                std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};
                return err;
            };
            errdefer dynlib.close();

            var api: Api = undefined;
            inline for (std.meta.fields(Api)) |field| {
                @field(api, field.name) = dynlib.lookup(field.type, field.name) orelse {
                    std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};
                    std.log.err("{s}: symbol {s} missing", .{ self.source_name, field.name });
                    return error.DynlibLookup;
                };
            }

            if (builtin.mode != .Debug) std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};

            return .{ dynlib, api, stat.mtime };
        }
    };
}

fn copyFile(source_path: []const u8, copy_path: []const u8, io: std.Io) !void {
    const source = try std.Io.Dir.cwd().openFile(io, source_path, .{});
    defer source.close(io);
    const copy = try std.Io.Dir.cwd().createFile(io, copy_path, .{});
    defer copy.close(io);
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_len = try source.readPositionalAll(io, &buffer, offset);
        if (read_len == 0) break;
        try copy.writePositionalAll(io, buffer[0..read_len], offset);
        offset += read_len;
        if (read_len < buffer.len) break;
    }
}

fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0], std.c.F_OK) == 0;
}
