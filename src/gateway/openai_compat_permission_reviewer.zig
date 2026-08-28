const std = @import("std");
const compat_endpoint = @import("../core/config/compat_endpoint.zig");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const openai_compat = @import("openai_compat.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewCompat,
};

fn reviewCompat(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = .openai_compatible_api_key,
        // The review runs on the model the turn is already using: fx cannot
        // pin a reviewer model on an endpoint whose catalog it does not own.
        .model = request.review_turn.model,
        .require_account = true,
        .validate_fn = validateCredential,
        .build_fn = openai_compat.buildRequest,
        .send_fn = sendPrepared,
    });
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    _ = compat_endpoint.normalizeBaseUrl(input.account_id orelse return error.InvalidAccount) catch
        return error.InvalidAccount;
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return openai_compat.streamPrepared(alloc, request, payload);
}

test "compat reviewer builds a chat completions request with the admitted model" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "User requested the change." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{
                .id = "call_review",
                .name = "write_file",
                .arguments_json = "{\"path\":\"a.txt\"}",
            }},
        },
        .{ .role = .system, .content = "Review the pending action." },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const body = try responses_reviewer.buildPayloadForTest(
        std.testing.allocator,
        "anthropic/claude-opus-4.6",
        &messages,
        "call_review",
        std.Io.Clock.Timestamp.fromNow(@import("../core/shared/io.zig").getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
        openai_compat.buildRequest,
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"anthropic/claude-opus-4.6\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_review\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "ai-gateway") == null);
}

test "compat reviewer refuses an endpoint it cannot validate" {
    try std.testing.expectError(error.InvalidAccount, validateCredential(std.testing.allocator, .{}));
    try std.testing.expectError(error.InvalidAccount, validateCredential(std.testing.allocator, .{
        .account_id = "http://openrouter.ai/api/v1",
    }));
    try validateCredential(std.testing.allocator, .{ .account_id = "https://openrouter.ai/api/v1" });
}
