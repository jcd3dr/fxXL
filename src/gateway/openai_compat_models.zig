//! Model catalog for a third-party OpenAI-compatible endpoint.
//!
//! `GET {base_url}/models` is the one listing every OpenAI-compatible service
//! agrees on. Its only guaranteed field is `data[].id`, so the parser treats
//! everything else as optional enrichment and never rejects a catalog for
//! lacking a field a particular router does not publish.

const std = @import("std");
const compat_endpoint = @import("../core/config/compat_endpoint.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

const max_catalog_models: usize = 4096;
const max_model_id_bytes: usize = 1024;
const max_catalog_bytes: usize = 16 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{ .ids = ids, .provenance = loaded.provenance } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    if (input.access.credentialSource() != .openai_compatible_api_key) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    // The configured endpoint travels as the credential's account identity.
    const base_url = input.access.accountId() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };

    const request_url = compat_endpoint.joinPath(alloc, base_url, compat_endpoint.models_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    var operation = FetchOperation{
        .alloc = alloc,
        .url = request_url,
        .credential = credential,
    };
    var response = gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(fetch_timeout_ms),
        }),
        &operation,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{
            .category = if (err == error.Cancelled) .cancellation else .transport,
            .retryable = err != error.Cancelled,
        } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "x-title", .value = "fx" },
                .{ .name = "http-referer", .value = "https://fx.sh" },
            },
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.CompatModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.CompatModelCatalogTooLarge;
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, body) };
    }
};

/// Parses the `{"data":[{"id":...}]}` listing. Optional metadata is read where a
/// router publishes it and defaulted where it does not.
pub fn parseCatalog(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCompatModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidCompatModelCatalog;
    if (data != .array or data.array.items.len > max_catalog_models) {
        return error.InvalidCompatModelCatalog;
    }

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |value| {
        if (value != .object) return error.InvalidCompatModelCatalog;
        const object = value.object;
        const raw_id = stringField(object, "id") orelse return error.InvalidCompatModelCatalog;
        if (!validModelId(raw_id)) return error.InvalidCompatModelCatalog;

        // Routers list embedding and moderation models next to chat models.
        // fx only drives chat completions, so skip anything a router marks otherwise.
        if (stringField(object, "object")) |kind| {
            if (!std.mem.eql(u8, kind, "model") and !std.mem.eql(u8, kind, "chat.completion")) continue;
        }

        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);

        const modalities = inputModalities(object);
        const has_reasoning = supportsReasoning(object);
        if (has_reasoning) {
            for ([_][]const u8{ "low", "medium", "high" }) |effort| {
                try reasoning_efforts.append(alloc, types.ReasoningEffort.parse(effort).?);
            }
        }

        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = optionalTimestamp(object),
            // Tool use is the baseline fx requires; an endpoint that rejects
            // tools reports that on the request, not in this listing.
            .has_tool_use = supportsTools(object),
            .has_reasoning = has_reasoning,
            .reasoning_efforts = reasoning_efforts,
            .has_vision = modalities.image,
            .has_file_input = modalities.file,
            .context_window = contextWindow(object),
            .max_tokens = maxOutputTokens(object),
        });
    }
    return catalog;
}

const Modalities = struct {
    image: bool = false,
    file: bool = false,
};

fn inputModalities(object: std.json.ObjectMap) Modalities {
    // OpenRouter nests these under `architecture`; other routers put them at the
    // top level. Read whichever is present.
    const source = if (object.get("architecture")) |value|
        if (value == .object) value.object else object
    else
        object;
    const modalities = source.get("input_modalities") orelse return .{};
    if (modalities != .array) return .{};
    var found: Modalities = .{};
    for (modalities.array.items) |entry| {
        if (entry != .string) continue;
        if (std.mem.eql(u8, entry.string, "image")) found.image = true;
        if (std.mem.eql(u8, entry.string, "file")) found.file = true;
    }
    return found;
}

fn supportsTools(object: std.json.ObjectMap) bool {
    if (object.get("supported_parameters")) |value| {
        if (value == .array) {
            for (value.array.items) |entry| {
                if (entry != .string) continue;
                if (std.mem.eql(u8, entry.string, "tools")) return true;
            }
            return false;
        }
    }
    // No published capability list: assume the model takes tools rather than
    // hiding it from the picker, and let the request itself be the proof.
    return true;
}

fn supportsReasoning(object: std.json.ObjectMap) bool {
    const value = object.get("supported_parameters") orelse return false;
    if (value != .array) return false;
    for (value.array.items) |entry| {
        if (entry != .string) continue;
        if (std.mem.eql(u8, entry.string, "reasoning") or
            std.mem.eql(u8, entry.string, "reasoning_effort")) return true;
    }
    return false;
}

fn contextWindow(object: std.json.ObjectMap) u32 {
    for ([_][]const u8{ "context_length", "context_window", "max_context_length" }) |key| {
        if (optionalPositiveU32(object, key)) |value| return value;
    }
    if (object.get("top_provider")) |provider| if (provider == .object) {
        if (optionalPositiveU32(provider.object, "context_length")) |value| return value;
    };
    return 0;
}

fn maxOutputTokens(object: std.json.ObjectMap) u32 {
    for ([_][]const u8{ "max_output_tokens", "max_completion_tokens" }) |key| {
        if (optionalPositiveU32(object, key)) |value| return value;
    }
    if (object.get("top_provider")) |provider| if (provider == .object) {
        if (optionalPositiveU32(provider.object, "max_completion_tokens")) |value| return value;
    };
    return 0;
}

fn optionalTimestamp(object: std.json.ObjectMap) i64 {
    const value = object.get("created") orelse return 0;
    if (value != .integer or value.integer < 0) return 0;
    return value.integer;
}

fn optionalPositiveU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer <= 0) return null;
    return std.math.cast(u32, value.integer);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_model_id_bytes) return false;
    for (id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

test "compat catalog reads the minimal OpenAI listing every endpoint publishes" {
    const alloc = std.testing.allocator;
    const json =
        \\{"object":"list","data":[
        \\  {"id":"gpt-5","object":"model","created":1730000000,"owned_by":"openai"},
        \\  {"id":"llama-3.3-70b","object":"model"}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-5", catalog.items[0].id);
    try std.testing.expectEqualStrings("language", catalog.items[0].model_type);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(!catalog.items[0].has_reasoning);
    try std.testing.expectEqual(@as(i64, 1730000000), catalog.items[0].released);
    try std.testing.expectEqualStrings("llama-3.3-70b", catalog.items[1].id);
    try std.testing.expectEqual(@as(i64, 0), catalog.items[1].released);
}

test "compat catalog reads OpenRouter capability metadata" {
    const alloc = std.testing.allocator;
    const json =
        \\{"data":[
        \\  {"id":"anthropic/claude-opus-4.6","object":"model","context_length":200000,
        \\   "architecture":{"input_modalities":["text","image","file"]},
        \\   "supported_parameters":["tools","reasoning","max_tokens"],
        \\   "top_provider":{"max_completion_tokens":64000}},
        \\  {"id":"meta/llama-guard","object":"model","supported_parameters":["max_tokens"]}
        \\]}
    ;
    var catalog = try parseCatalog(alloc, json);
    defer model_catalog.freeModelCatalog(alloc, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    const opus = catalog.items[0];
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", opus.id);
    try std.testing.expect(opus.has_tool_use);
    try std.testing.expect(opus.has_reasoning);
    try std.testing.expectEqual(@as(usize, 3), opus.reasoning_efforts.items.len);
    try std.testing.expect(opus.has_vision);
    try std.testing.expect(opus.has_file_input);
    try std.testing.expectEqual(@as(u32, 200_000), opus.context_window);
    try std.testing.expectEqual(@as(u32, 64_000), opus.max_tokens);

    const guard = catalog.items[1];
    try std.testing.expect(!guard.has_tool_use);
    try std.testing.expect(!guard.has_reasoning);
    try std.testing.expect(!guard.has_vision);
}

test "compat catalog skips non-chat entries and rejects an unusable listing" {
    const alloc = std.testing.allocator;
    var catalog = try parseCatalog(alloc,
        \\{"data":[{"id":"text-embedding-3","object":"embedding"},{"id":"gpt-5","object":"model"}]}
    );
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-5", catalog.items[0].id);

    try std.testing.expectError(error.InvalidCompatModelCatalog, parseCatalog(alloc, "{\"models\":[]}"));
    try std.testing.expectError(error.InvalidCompatModelCatalog, parseCatalog(alloc, "{\"data\":[{\"name\":\"x\"}]}"));
    try std.testing.expectError(
        error.InvalidCompatModelCatalog,
        parseCatalog(alloc, "{\"data\":[{\"id\":\"bad\\nid\",\"object\":\"model\"}]}"),
    );
}

test "compat catalog rejects a credential from another route" {
    const access = @import("../core/auth/credentials.zig").catalogAccessForCredential(
        .ai_gateway_api_key,
        "gateway-key",
        null,
    );
    const result = try fetchCatalogForProvider(null, std.testing.allocator, .{
        .access = access,
        .endpoint = "/models",
    });
    try std.testing.expectEqual(model_catalog.FailureCategory.authentication, result.failure.category);
}
