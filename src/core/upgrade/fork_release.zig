const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_manifest_bytes: usize = 4096;
pub const stable_release_base = "https://github.com/jcd3dr/fxXL/releases/latest/download";

pub const Manifest = struct {
    schema_version: u32,
    version: []u8,
    upstream_commit: []u8,
    source_commit: []u8,

    pub fn parse(alloc: Allocator, bytes: []const u8) !Manifest {
        if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidManifest,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidManifest;

        const schema_value = parsed.value.object.get("schema_version") orelse
            return error.InvalidManifest;
        const version_value = parsed.value.object.get("version") orelse
            return error.InvalidManifest;
        const upstream_value = parsed.value.object.get("upstream_commit") orelse
            return error.InvalidManifest;
        const source_value = parsed.value.object.get("source_commit") orelse
            return error.InvalidManifest;
        if (schema_value != .integer or
            version_value != .string or
            upstream_value != .string or
            source_value != .string or
            schema_value.integer != 1 or
            !validVersion(version_value.string) or
            !validCommit(upstream_value.string) or
            !validCommit(source_value.string))
        {
            return error.InvalidManifest;
        }

        const version = try alloc.dupe(u8, version_value.string);
        errdefer alloc.free(version);
        const upstream_commit = try alloc.dupe(u8, upstream_value.string);
        errdefer alloc.free(upstream_commit);
        const source_commit = try alloc.dupe(u8, source_value.string);
        return .{
            .schema_version = 1,
            .version = version,
            .upstream_commit = upstream_commit,
            .source_commit = source_commit,
        };
    }

    pub fn deinit(self: *Manifest, alloc: Allocator) void {
        alloc.free(self.version);
        alloc.free(self.upstream_commit);
        alloc.free(self.source_commit);
        self.* = undefined;
    }
};

pub fn manifestUrl(alloc: Allocator, release_base: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/manifest.json", .{release_base});
}

pub fn assetUrl(alloc: Allocator, release_base: []const u8, release_platform: []const u8) ![]u8 {
    if (!supportedPlatform(release_platform)) return error.UnsupportedPlatform;
    return std.fmt.allocPrint(alloc, "{s}/fx-{s}.tar.gz", .{ release_base, release_platform });
}

pub fn checksumUrl(alloc: Allocator, release_base: []const u8, release_platform: []const u8) ![]u8 {
    if (!supportedPlatform(release_platform)) return error.UnsupportedPlatform;
    return std.fmt.allocPrint(alloc, "{s}/fx-{s}.tar.gz.sha256", .{ release_base, release_platform });
}

fn supportedPlatform(release_platform: []const u8) bool {
    return std.mem.eql(u8, release_platform, "linux-x86_64") or
        std.mem.eql(u8, release_platform, "linux-aarch64") or
        std.mem.eql(u8, release_platform, "macos-x86_64") or
        std.mem.eql(u8, release_platform, "macos-aarch64");
}

fn validVersion(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > 32) return false;
    var part_count: usize = 0;
    var parts = std.mem.splitScalar(u8, raw, '.');
    while (parts.next()) |part| {
        if (part_count == 3 or part.len == 0) return false;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return false;
        _ = std.fmt.parseUnsigned(u32, part, 10) catch return false;
        part_count += 1;
    }
    return part_count == 3;
}

fn validCommit(raw: []const u8) bool {
    if (raw.len != 40) return false;
    for (raw) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

test "parse a valid fxXL release manifest" {
    var manifest = try Manifest.parse(std.testing.allocator,
        \\{"schema_version":1,"version":"0.1.0","upstream_commit":"0123456789abcdef0123456789abcdef01234567","source_commit":"89abcdef0123456789abcdef0123456789abcdef"}
    );
    defer manifest.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), manifest.schema_version);
    try std.testing.expectEqualStrings("0.1.0", manifest.version);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        manifest.upstream_commit,
    );
    try std.testing.expectEqualStrings(
        "89abcdef0123456789abcdef0123456789abcdef",
        manifest.source_commit,
    );
}

test "reject invalid fxXL release manifests" {
    const cases = [_][]const u8{
        \\{"schema_version":2,"version":"0.1.0","upstream_commit":"0123456789abcdef0123456789abcdef01234567","source_commit":"89abcdef0123456789abcdef0123456789abcdef"}
        ,
        \\{"schema_version":1,"version":"v0.1.0","upstream_commit":"0123456789abcdef0123456789abcdef01234567","source_commit":"89abcdef0123456789abcdef0123456789abcdef"}
        ,
        \\{"schema_version":1,"version":"0.1","upstream_commit":"0123456789abcdef0123456789abcdef01234567","source_commit":"89abcdef0123456789abcdef0123456789abcdef"}
        ,
        \\{"schema_version":1,"version":"0.1.0","upstream_commit":"short","source_commit":"89abcdef0123456789abcdef0123456789abcdef"}
        ,
        \\{"schema_version":1,"version":"0.1.0","upstream_commit":"0123456789abcdef0123456789abcdef0123456z","source_commit":"89abcdef0123456789abcdef0123456789abcdef"}
        ,
        \\{"schema_version":1,"version":"0.1.0","upstream_commit":"0123456789abcdef0123456789abcdef01234567","source_commit":"short"}
        ,
    };

    for (cases) |bytes| {
        try std.testing.expectError(
            error.InvalidManifest,
            Manifest.parse(std.testing.allocator, bytes),
        );
    }

    var oversized: [max_manifest_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectError(
        error.ManifestTooLarge,
        Manifest.parse(std.testing.allocator, &oversized),
    );
}

test "build stable fxXL GitHub release URLs" {
    const alloc = std.testing.allocator;
    const manifest_url = try manifestUrl(alloc, stable_release_base);
    defer alloc.free(manifest_url);
    try std.testing.expectEqualStrings(
        "https://github.com/jcd3dr/fxXL/releases/latest/download/manifest.json",
        manifest_url,
    );

    const asset_url = try assetUrl(alloc, stable_release_base, "linux-x86_64");
    defer alloc.free(asset_url);
    try std.testing.expectEqualStrings(
        "https://github.com/jcd3dr/fxXL/releases/latest/download/fx-linux-x86_64.tar.gz",
        asset_url,
    );

    const checksum_url = try checksumUrl(alloc, stable_release_base, "linux-x86_64");
    defer alloc.free(checksum_url);
    try std.testing.expectEqualStrings(
        "https://github.com/jcd3dr/fxXL/releases/latest/download/fx-linux-x86_64.tar.gz.sha256",
        checksum_url,
    );
}

test "build macOS release URL without requiring a macOS installer" {
    const url = try assetUrl(std.testing.allocator, stable_release_base, "macos-x86_64");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/jcd3dr/fxXL/releases/latest/download/fx-macos-x86_64.tar.gz",
        url,
    );
}

test "reject unsupported fxXL release platforms" {
    try std.testing.expectError(
        error.UnsupportedPlatform,
        checksumUrl(std.testing.allocator, stable_release_base, "linux-riscv64"),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        assetUrl(std.testing.allocator, stable_release_base, "windows-x86_64"),
    );
}
