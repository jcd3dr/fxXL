//! Endpoint policy for the OpenAI-compatible third-party provider.
//!
//! fx never guesses a third-party base URL. The user supplies one, either
//! through `FX_COMPAT_BASE_URL` or through the stored compat session written
//! by `fx login compat`. This module owns the only validation those values get,
//! so the transport and the model catalog build their URLs from the same rules.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const base_url_env = "FX_COMPAT_BASE_URL";
pub const api_key_env = "FX_COMPAT_API_KEY";

pub const max_base_url_bytes: usize = 1024;
pub const max_api_key_bytes: usize = 8 * 1024;

/// A well-known router, offered as guidance in setup output only. fx does not
/// default to any of these: the user always names the endpoint it talks to.
pub const Suggestion = struct {
    name: []const u8,
    base_url: []const u8,
};

pub const suggestions = [_]Suggestion{
    .{ .name = "OpenRouter", .base_url = "https://openrouter.ai/api/v1" },
    .{ .name = "Omnirouter", .base_url = "https://omnirouter.ai/v1" },
};

pub const ValidationError = error{
    CompatBaseUrlEmpty,
    CompatBaseUrlTooLong,
    CompatBaseUrlNotAbsolute,
    CompatBaseUrlInsecure,
    CompatBaseUrlHasCredentials,
    CompatBaseUrlHasQuery,
    CompatApiKeyEmpty,
    CompatApiKeyTooLong,
    CompatApiKeyUnsafe,
};

/// Trims a configured base URL and rejects anything the transport could not
/// safely append a path to. Returns a slice of `raw`.
pub fn normalizeBaseUrl(raw: []const u8) ValidationError![]const u8 {
    const trimmed = trimTrailingSlashes(std.mem.trim(u8, raw, " \t\r\n"));
    if (trimmed.len == 0) return error.CompatBaseUrlEmpty;
    if (trimmed.len > max_base_url_bytes) return error.CompatBaseUrlTooLong;
    for (trimmed) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.CompatBaseUrlNotAbsolute;
    }

    const uri = std.Uri.parse(trimmed) catch return error.CompatBaseUrlNotAbsolute;
    if (uri.host == null) return error.CompatBaseUrlNotAbsolute;
    if (uri.user != null or uri.password != null) return error.CompatBaseUrlHasCredentials;
    if (uri.query != null or uri.fragment != null) return error.CompatBaseUrlHasQuery;

    // Plaintext HTTP is allowed only for a loopback endpoint: a local router,
    // a proxy, or an on-device server. Anything else must use TLS, because the
    // API key travels in the Authorization header.
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return trimmed;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.CompatBaseUrlNotAbsolute;
    if (!isLoopbackHost(uri)) return error.CompatBaseUrlInsecure;
    return trimmed;
}

/// Rejects a key that could not sit in an Authorization header.
pub fn validateApiKey(raw: []const u8) ValidationError![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.CompatApiKeyEmpty;
    if (trimmed.len > max_api_key_bytes) return error.CompatApiKeyTooLong;
    for (trimmed) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.CompatApiKeyUnsafe;
    }
    return trimmed;
}

/// Joins a validated base URL with an absolute API path. The caller owns the result.
pub fn joinPath(alloc: Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0 and path[0] == '/');
    const normalized = try normalizeBaseUrl(base_url);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ normalized, path });
}

pub const chat_completions_path = "/chat/completions";
pub const models_path = "/models";

pub fn message(err: ValidationError) []const u8 {
    return switch (err) {
        error.CompatBaseUrlEmpty => "set a base URL for the OpenAI-compatible endpoint",
        error.CompatBaseUrlTooLong => "the base URL is too long",
        error.CompatBaseUrlNotAbsolute => "the base URL must be an absolute http or https URL",
        error.CompatBaseUrlInsecure => "a plain http base URL is accepted only on loopback; use https",
        error.CompatBaseUrlHasCredentials => "the base URL must not embed a user or password",
        error.CompatBaseUrlHasQuery => "the base URL must not carry a query string or fragment",
        error.CompatApiKeyEmpty => "set an API key for the OpenAI-compatible endpoint",
        error.CompatApiKeyTooLong => "the API key is too long",
        error.CompatApiKeyUnsafe => "the API key contains characters an HTTP header cannot carry",
    };
}

fn trimTrailingSlashes(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') end -= 1;
    return value[0..end];
}

fn isLoopbackHost(uri: std.Uri) bool {
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]");
}

test "compat base URL normalization trims and keeps an https origin" {
    try std.testing.expectEqualStrings(
        "https://openrouter.ai/api/v1",
        try normalizeBaseUrl("  https://openrouter.ai/api/v1/  "),
    );
    try std.testing.expectEqualStrings(
        "https://omnirouter.ai/v1",
        try normalizeBaseUrl("https://omnirouter.ai/v1"),
    );
}

test "compat base URL rejects unsafe origins" {
    try std.testing.expectError(error.CompatBaseUrlEmpty, normalizeBaseUrl("   "));
    try std.testing.expectError(error.CompatBaseUrlNotAbsolute, normalizeBaseUrl("openrouter.ai/api/v1"));
    try std.testing.expectError(error.CompatBaseUrlNotAbsolute, normalizeBaseUrl("ftp://openrouter.ai/v1"));
    try std.testing.expectError(error.CompatBaseUrlInsecure, normalizeBaseUrl("http://openrouter.ai/api/v1"));
    try std.testing.expectError(error.CompatBaseUrlHasCredentials, normalizeBaseUrl("https://user:pass@host/v1"));
    try std.testing.expectError(error.CompatBaseUrlHasQuery, normalizeBaseUrl("https://host/v1?key=leak"));
    try std.testing.expectError(error.CompatBaseUrlNotAbsolute, normalizeBaseUrl("https://host/v1\nX-Injected: 1"));
    try std.testing.expectError(error.CompatBaseUrlTooLong, normalizeBaseUrl("https://host/" ++ "a" ** max_base_url_bytes));
}

test "compat base URL allows plaintext loopback for a local router" {
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", try normalizeBaseUrl("http://127.0.0.1:11434/v1"));
    try std.testing.expectEqualStrings("http://localhost:4000", try normalizeBaseUrl("http://localhost:4000/"));
}

test "compat API key must be header safe" {
    try std.testing.expectEqualStrings("sk-or-v1-abc", try validateApiKey("  sk-or-v1-abc \n"));
    try std.testing.expectError(error.CompatApiKeyEmpty, validateApiKey(""));
    try std.testing.expectError(error.CompatApiKeyUnsafe, validateApiKey("sk-abc\r\nX-Injected: 1"));
    try std.testing.expectError(error.CompatApiKeyUnsafe, validateApiKey("sk abc"));
    try std.testing.expectError(error.CompatApiKeyTooLong, validateApiKey("k" ** (max_api_key_bytes + 1)));
}

test "compat path join builds the documented OpenAI routes" {
    const alloc = std.testing.allocator;
    const chat = try joinPath(alloc, "https://openrouter.ai/api/v1/", chat_completions_path);
    defer alloc.free(chat);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", chat);

    const models = try joinPath(alloc, "https://openrouter.ai/api/v1", models_path);
    defer alloc.free(models);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/models", models);
}
