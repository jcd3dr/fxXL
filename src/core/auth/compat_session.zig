//! Stored credential for the OpenAI-compatible third-party provider.
//!
//! The session holds the endpoint the user chose and the API key for it. It
//! lives beside the other provider sessions at `~/.fx/compat-auth.json` with
//! the same private-directory and private-file guarantees, and is never sent
//! to Vercel AI Gateway, OpenAI, or xAI.

const std = @import("std");
const compat_endpoint = @import("../config/compat_endpoint.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const mutation_lock_file_name = "compat-auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;
const max_label_bytes: usize = 128;

const auth_file_name = profile_paths.compat_auth_file_name;

pub const Session = struct {
    base_url: []u8,
    api_key: []u8,
    /// Optional human-readable name for the endpoint, shown in fx output.
    label: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.base_url);
        secret.zeroAndFree(alloc, self.api_key);
        alloc.free(self.label);
        self.* = undefined;
    }
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub fn validLabel(label: []const u8) bool {
    if (label.len > max_label_bytes) return false;
    for (label) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

/// Derives a display label from a base URL when the user supplied none.
/// Returns a slice of `base_url`.
pub fn labelForBaseUrl(base_url: []const u8) []const u8 {
    const uri = std.Uri.parse(base_url) catch return base_url;
    const host_component = uri.host orelse return base_url;
    return switch (host_component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
}

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.fx_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "compat session load failed step=open_home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("auth", "compat session load failed step=open_profile err={s}", .{@errorName(err)});
        }
        return null;
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "compat session load failed step=open_file err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "compat session load failed step=permissions err=InsecureAuthFile", .{});
        return null;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "compat session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.CompatSessionUnavailable;
    var mutation = try beginMutation();
    defer mutation.deinit();
    const text = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, text);
    try io_mod.durableReplaceVerified(alloc, &mutation.fx_dir, auth_file_name, text);
}

pub fn logout() !DeleteOutcome {
    if (comptime host_target.is_wasm) return .missing;
    var mutation = (try beginExistingMutation()) orelse return .missing;
    defer mutation.deinit();
    return mutation.delete();
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try lockMutation(fx_dir);
}

fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(fx_dir);
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &fx_dir,
        mutation_lock_file_name,
        mutation_lock_deadline_ms,
    );
    errdefer lock.release();
    return .{ .fx_dir = fx_dir, .lock = lock };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());

    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) return error.PrivateStatePermissionsUnsupported;
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

/// Builds an owned session from raw user input, applying the endpoint policy.
pub fn build(
    alloc: Allocator,
    raw_base_url: []const u8,
    raw_api_key: []const u8,
    raw_label: ?[]const u8,
) !Session {
    const base_url = try compat_endpoint.normalizeBaseUrl(raw_base_url);
    const api_key = try compat_endpoint.validateApiKey(raw_api_key);
    const label_source = blk: {
        const candidate = std.mem.trim(u8, raw_label orelse "", " \t\r\n");
        break :blk if (candidate.len > 0) candidate else labelForBaseUrl(base_url);
    };
    if (!validLabel(label_source)) return error.InvalidCompatSession;

    const owned_base_url = try alloc.dupe(u8, base_url);
    errdefer alloc.free(owned_base_url);
    const owned_api_key = try alloc.dupe(u8, api_key);
    errdefer secret.zeroAndFree(alloc, owned_api_key);
    const owned_label = try alloc.dupe(u8, label_source);
    return .{ .base_url = owned_base_url, .api_key = owned_api_key, .label = owned_label };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCompatSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidCompatSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidCompatSession;

    const base_url = try requiredString(object, "base_url");
    const api_key = try requiredString(object, "api_key");
    const label = if (object.get("label")) |value| blk: {
        if (value != .string) return error.InvalidCompatSession;
        break :blk value.string;
    } else "";

    return build(alloc, base_url, api_key, label) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCompatSession,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    _ = try compat_endpoint.normalizeBaseUrl(session.base_url);
    _ = try compat_endpoint.validateApiKey(session.api_key);
    if (!validLabel(session.label)) return error.InvalidCompatSession;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"base_url\":");
    try std.json.Stringify.value(session.base_url, .{}, &out.writer);
    try out.writer.writeAll(",\"api_key\":");
    try std.json.Stringify.value(session.api_key, .{}, &out.writer);
    try out.writer.writeAll(",\"label\":");
    try std.json.Stringify.value(session.label, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidCompatSession;
    if (value != .string or value.string.len == 0) return error.InvalidCompatSession;
    return value.string;
}

test "compat session round trips through its persisted form" {
    const alloc = std.testing.allocator;
    var session = try build(alloc, "https://openrouter.ai/api/v1/", "sk-or-v1-secret", null);
    defer session.deinit(alloc);

    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", session.base_url);
    try std.testing.expectEqualStrings("openrouter.ai", session.label);

    const encoded = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try parse(alloc, encoded);
    defer decoded.deinit(alloc);

    try std.testing.expectEqualStrings(session.base_url, decoded.base_url);
    try std.testing.expectEqualStrings(session.api_key, decoded.api_key);
    try std.testing.expectEqualStrings(session.label, decoded.label);
}

test "compat session keeps an explicit label" {
    const alloc = std.testing.allocator;
    var session = try build(alloc, "https://omnirouter.ai/v1", "sk-secret", "Team router");
    defer session.deinit(alloc);
    try std.testing.expectEqualStrings("Team router", session.label);
}

test "compat session rejects unusable endpoints and keys" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.CompatBaseUrlInsecure, build(alloc, "http://openrouter.ai/v1", "sk-a", null));
    try std.testing.expectError(error.CompatApiKeyUnsafe, build(alloc, "https://openrouter.ai/v1", "sk\r\na", null));
    try std.testing.expectError(error.CompatApiKeyEmpty, build(alloc, "https://openrouter.ai/v1", "  ", null));
}

test "compat session parse rejects a malformed or wrong-version record" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidCompatSession, parse(alloc, "{\"version\":2,\"base_url\":\"https://a/v1\",\"api_key\":\"k\"}"));
    try std.testing.expectError(error.InvalidCompatSession, parse(alloc, "{\"version\":1,\"base_url\":\"https://a/v1\"}"));
    try std.testing.expectError(error.InvalidCompatSession, parse(alloc, "{\"version\":1,\"base_url\":\"not a url\",\"api_key\":\"k\"}"));
}
