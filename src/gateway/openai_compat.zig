//! Streaming transport for a third-party OpenAI-compatible endpoint.
//!
//! The endpoint travels with the credential as its account identity, so this
//! transport never reads configuration behind the agent's back and never sends
//! the key anywhere but the base URL the user configured.

const std = @import("std");
const compat_endpoint = @import("../core/config/compat_endpoint.zig");
const io_mod = @import("../core/shared/io.zig");
const responses_protocol = @import("responses_protocol.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const compat_protocol = @import("openai_compat_protocol.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const limits = compat_protocol.Limits{
    .tool_calls = 128,
    .tool_identity_bytes = 1024,
    .tool_arguments_bytes = 4 * 1024 * 1024,
    .content_bytes = 16 * 1024 * 1024,
    .generation_id_bytes = 256,
};

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
};

/// Serializes one request body. Shared with the permission reviewer so both
/// paths produce byte-identical requests.
pub fn buildRequest(alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    return compat_protocol.buildRequest(alloc, request, limits);
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source != .openai_compatible_api_key) {
        return error.CompatCredentialRequired;
    }
    _ = try requestBaseUrl(request);
    try compat_protocol.validateModel(request.model);

    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);
    var result = streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (requestDeadlineExpired(request)) return error.Timeout;
        request.attempt_evidence.network_failure =
            gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return error.Timeout;
    }
    return result;
}

fn requestBaseUrl(request: stream_provider.ModelRequest) ![]const u8 {
    const account = request.credential.account_id orelse return error.CompatEndpointRequired;
    return compat_endpoint.normalizeBaseUrl(account) catch error.InvalidCompatEndpoint;
}

fn requestDeadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: []const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const base_url = try requestBaseUrl(request);
    const chat_url = try compat_endpoint.joinPath(alloc, base_url, compat_endpoint.chat_completions_path);
    defer alloc.free(chat_url);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, auth_header);
    const uri = std.Uri.parse(chat_url) catch return error.InvalidCompatEndpoint;

    // Routers that attribute traffic read these; the rest ignore them.
    const extra_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "x-title", .value = "fx" },
        .{ .name = "http-referer", .value = "https://fx.sh" },
    };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
        .extra_headers = &extra_headers,
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
            connect_deadline = deadline;
        }
    }
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        if (request.deadline) |deadline|
            try gateway_client.spawnHttpCancelWatcherBounded(
                &cancel_watch_done,
                request.cancel_flag,
                deadline,
                connection.stream_writer.stream,
            )
        else
            try gateway_client.spawnHttpCancelWatcher(
                &cancel_watch_done,
                request.cancel_flag,
                connection.stream_writer.stream,
            )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, compat_error_too_large),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, compat_error_too_large);
        } else bounded_body;
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .retry_after_seconds = retryAfterSeconds(response.head),
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    const reduced = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
    );
    // An endpoint that streams `{"error":...}` after a 200 head is still a
    // failed generation; report the message it sent rather than a bare error.
    if (reduced.failure_detail) |detail| {
        return .{ .failed = .{
            .kind = .provider_error,
            .detail = detail,
            .ownership = .owned,
        } };
    }
    var completion = reduced.completion;
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }

    // A third-party endpoint bills on its own ledger. Report the token counts it
    // returned without inventing a price fx cannot know.
    const usage_outcome: stream_provider.UsageOutcome = usage: {
        if (completion.generation_id == null) break :usage .{ .unavailable = .possibly_billed };
        completion.billing = try responses_protocol.buildSubscriptionBilling(
            alloc,
            .compat,
            request.model,
            @max(io_mod.milliTimestamp(), 0),
            completion.usage,
        ) orelse break :usage .{ .unavailable = .possibly_billed };
        break :usage .{ .exact = .compat };
    };
    return .{ .completed = .{
        .completion = completion,
        .usage = usage_outcome,
        .ownership = .owned,
    } };
}

const compat_error_too_large = "OpenAI-compatible error response exceeded the local limit";

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request, .not_found, .unprocessable_entity => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden, .payment_required => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

fn retryAfterSeconds(head: std.http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
        const trimmed = std.mem.trim(u8, header.value, " \t");
        return std.fmt.parseInt(u64, trimmed, 10) catch null;
    }
    return null;
}

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,

    const Line = struct {
        bytes: []const u8,
        wire_bytes: usize,
    };

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = responses_protocol.checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            ) catch return error.CompatResourceLimitExceeded;
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            // Blank lines separate events; a leading colon is a keepalive
            // comment, which routers send while an upstream model warms up.
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            if (data.len == 0) {
                self.release();
                continue;
            }
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.CompatSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.CompatSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) {
                    return .{
                        .bytes = self.pending_line.items,
                        .wire_bytes = self.pending_line.items.len,
                    };
                }
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.CompatSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) {
                return .{ .bytes = fragment, .wire_bytes = fragment.len + 1 };
            }
            try self.pending_line.appendSlice(alloc, fragment);
            return .{
                .bytes = self.pending_line.items,
                .wire_bytes = self.pending_line.items.len + 1,
            };
        }
    }
};

/// Either a completed generation or the inline error the endpoint streamed.
/// Exactly one field is set; both are owned by the caller.
const Reduced = struct {
    completion: types.ModelCompletion = .{},
    failure_detail: ?[]u8 = null,
};

fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !Reduced {
    var reducer = compat_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    const callbacks = compat_protocol.StreamCallbacks{
        .context = callback_ctx,
        .on_content = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning = on_reasoning_chunk,
        .on_tool_input = on_tool_input_chunk,
    };
    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (reducer.applyJson(
            alloc,
            json_text,
            callbacks,
            cancel_flag,
            content_capture_limit,
            limits,
        ) catch |err| return mapReducerError(err)) break;
    }
    const completion = reducer.finish(alloc, cancel_flag) catch |err| {
        if (err == error.CompatResponseFailed) {
            if (reducer.takeFailureDetail()) |detail| return .{ .failure_detail = detail };
        }
        return mapReducerError(err);
    };
    return .{ .completion = completion };
}

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidCompatSseEvent,
        error.ResourceLimitExceeded => error.CompatResourceLimitExceeded,
        else => err,
    };
}

test "compat transport refuses a credential from another route before any I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;

    try std.testing.expectError(
        error.CompatCredentialRequired,
        agent_stream_provider.stream(std.testing.allocator, testModelRequest(
            "gateway-key",
            .ai_gateway_api_key,
            "https://openrouter.ai/api/v1",
            &delivery,
            &evidence,
            &cancelled,
            &callback_context,
        )),
    );
    try std.testing.expectEqual(
        stream_provider.DeliveryCertainty.State.definitely_unsent,
        delivery.load(),
    );
}

test "compat transport requires a configured endpoint before any I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;

    try std.testing.expectError(
        error.CompatEndpointRequired,
        agent_stream_provider.stream(std.testing.allocator, testModelRequest(
            "sk-key",
            .openai_compatible_api_key,
            null,
            &delivery,
            &evidence,
            &cancelled,
            &callback_context,
        )),
    );
    try std.testing.expectError(
        error.InvalidCompatEndpoint,
        agent_stream_provider.stream(std.testing.allocator, testModelRequest(
            "sk-key",
            .openai_compatible_api_key,
            "http://openrouter.ai/api/v1",
            &delivery,
            &evidence,
            &cancelled,
            &callback_context,
        )),
    );
    try std.testing.expectEqual(
        stream_provider.DeliveryCertainty.State.definitely_unsent,
        delivery.load(),
    );
}

fn testModelRequest(
    secret_value: []const u8,
    source: types.CredentialSource,
    account_id: ?[]const u8,
    delivery: *stream_provider.DeliveryCertainty,
    evidence: *stream_provider.AttemptEvidence,
    cancelled: *std.atomic.Value(bool),
    callback_context: *u8,
) stream_provider.ModelRequest {
    return .{
        .credential = .{
            .secret = secret_value,
            .source = source,
            .account_id = account_id,
        },
        .model = "anthropic/claude-opus-4.6",
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .none,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = delivery,
        .attempt_evidence = evidence,
        .events = .{ .context = callback_context, .emit_fn = ignoreTestEvent },
        .admission = .{ .context = callback_context, .admit_fn = admitTestRequest },
        .cancel_flag = cancelled,
    };
}

fn ignoreTestEvent(_: *anyopaque, _: stream_provider.Event) void {}

fn admitTestRequest(_: *anyopaque) !void {}

test "compat SSE reader skips keepalive comments and stops at the done sentinel" {
    const sse_text =
        ": OPENROUTER PROCESSING\n\n" ++
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\n" ++
        "data: [DONE]\n\n" ++
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ignored\"}}]}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);

    const Capture = struct {
        content: std.ArrayList(u8) = .empty,

        fn chunk(raw: *anyopaque, value: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, value) catch unreachable;
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);

    const reduced = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.chunk,
        null,
        null,
        null,
        &cancelled,
        null,
    );
    defer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = reduced.completion,
            .ownership = .owned,
        } };
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expect(reduced.failure_detail == null);
    try std.testing.expectEqualStrings("hi", capture.content.items);
    try std.testing.expectEqualStrings("hi", reduced.completion.content.?);
    try std.testing.expectEqualStrings("gen-1", reduced.completion.generation_id.?);
}

test "compat SSE surfaces the endpoint's own message for an inline error" {
    const sse_text =
        "data: {\"id\":\"gen-2\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n" ++
        "data: {\"error\":{\"message\":\"upstream model is overloaded\",\"code\":502}}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var discarded: u8 = 0;

    const reduced = try consumeSse(
        std.testing.allocator,
        &reader,
        &discarded,
        discardTestChunk,
        null,
        null,
        null,
        &cancelled,
        null,
    );
    defer if (reduced.failure_detail) |detail| std.testing.allocator.free(detail);

    try std.testing.expectEqualStrings("upstream model is overloaded", reduced.failure_detail.?);
    try std.testing.expect(reduced.completion.content == null);
}

fn discardTestChunk(_: *anyopaque, _: []const u8) void {}

test "compat failure kinds map the statuses routers actually return" {
    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, failureKind(.unauthorized));
    try std.testing.expectEqual(stream_provider.FailureKind.forbidden, failureKind(.payment_required));
    try std.testing.expectEqual(stream_provider.FailureKind.rate_limited, failureKind(.too_many_requests));
    try std.testing.expectEqual(stream_provider.FailureKind.invalid_request, failureKind(.not_found));
    try std.testing.expectEqual(stream_provider.FailureKind.bad_gateway, failureKind(.bad_gateway));
}
