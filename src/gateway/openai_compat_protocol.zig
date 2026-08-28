//! Wire protocol for OpenAI-compatible Chat Completions endpoints.
//!
//! This module is transport-free. It serializes a provider-neutral
//! `stream_provider.RequestData` into the Chat Completions request body every
//! OpenAI-compatible inference service accepts, and reduces the
//! `chat.completion.chunk` server-sent event stream back into a neutral
//! `types.ModelCompletion`.
//!
//! Third-party routers differ in the optional fields they emit. The reducer
//! accepts the documented OpenAI shape and the two reasoning-delta spellings
//! routers add on top of it, and ignores every field it does not model.

const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
    content_bytes: usize,
    generation_id_bytes: usize,
};

pub const StreamCallbacks = struct {
    context: *anyopaque,
    on_content: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback = null,
    on_reasoning: ?stream_provider.StreamCallback = null,
    on_tool_input: ?stream_provider.StreamCallback = null,
};

const InputSchema = union(enum) {
    static: model_tool_schema.ObjectSchema,
    dynamic: std.json.Value,
};

pub fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidCompatModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidCompatModel;
    }
}

/// Serializes one streaming Chat Completions request. The caller owns the result.
pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
    limits: Limits,
) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    try writeMessages(writer, alloc, request.messages, request.verified_images, limits);
    try writer.writeByte(']');

    const tool_count = try writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
        try writer.writeAll(",\"parallel_tool_calls\":true");
    }

    if (request.provider_options.reasoning) |effort| {
        if (effort.gatewayValue()) |value| {
            try writer.writeAll(",\"reasoning_effort\":");
            try std.json.Stringify.value(value, .{}, writer);
        }
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeMessages(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    limits: Limits,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => {
                const content = message.content orelse continue;
                if (content.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(content, .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                const images = attachedImages(verified_images, message_index, messages.len);
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":");
                if (images.len == 0) {
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                } else {
                    try writer.writeByte('[');
                    var first_part = true;
                    if (message.content) |content| if (content.len > 0) {
                        try writer.writeAll("{\"type\":\"text\",\"text\":");
                        try std.json.Stringify.value(content, .{}, writer);
                        try writer.writeByte('}');
                        first_part = false;
                    };
                    for (images) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImagePart(writer, alloc, image);
                        first_part = false;
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .assistant => {
                try validateReplayMessage(message, limits);
                const content = message.content orelse "";
                if (content.len == 0 and message.tool_calls.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                try std.json.Stringify.value(content, .{}, writer);
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, index| {
                        if (index > 0) try writer.writeByte(',');
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(
                            if (call.arguments_json.len == 0) "{}" else call.arguments_json,
                            .{},
                            writer,
                        );
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn attachedImages(
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    message_index: usize,
    message_count: usize,
) []const image_attachments.VerifiedSnapshot {
    const images = verified_images orelse return &.{};
    if (message_index + 1 != message_count) return &.{};
    return images;
}

fn writeImagePart(
    writer: *std.Io.Writer,
    alloc: Allocator,
    image: image_attachments.VerifiedSnapshot,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

fn validateReplayMessage(message: types.ChatMessage, limits: Limits) !void {
    if (message.tool_calls.len > limits.tool_calls) return error.ToolCallLimitExceeded;
    for (message.tool_calls) |call| {
        if (call.id.len == 0 or call.id.len > limits.tool_identity_bytes or
            call.name.len == 0 or call.name.len > limits.tool_identity_bytes)
        {
            return error.ToolCallLimitExceeded;
        }
        if (call.arguments_json.len > limits.tool_arguments_bytes) {
            return error.ToolArgumentsTooLarge;
        }
    }
}

/// Serializes the provider-neutral function tool selection into the Chat
/// Completions `tools` array. Returns the number of tools written.
pub fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    tools: stream_provider.ToolSelection,
) !usize {
    var count: usize = 0;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(",\"tools\":[");

    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(&out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(&out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(&out.writer, alloc, tool.name, tool.description, .{ .dynamic = tool.input_schema });
        count += 1;
    }
    try out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(out.written());
    return count;
}

fn writeFunctionTool(
    writer: *std.Io.Writer,
    alloc: Allocator,
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
) !void {
    if (name.len == 0) return error.InvalidToolSchema;
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    if (description.len > 0) {
        try writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, description);
    }
    try writer.writeAll(",\"parameters\":");
    switch (input_schema) {
        .static => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
        .dynamic => |schema| {
            if (schema != .object) return error.InvalidToolSchema;
            try std.json.Stringify.value(schema, .{}, writer);
        },
    }
    try writer.writeAll("}}");
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

const ToolAccumulator = struct {
    index: i64,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

/// Accumulates one Chat Completions stream. `applyJson` consumes a single
/// `data:` payload; `finish` produces the completion the agent consumes.
pub const Reducer = struct {
    content: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolAccumulator) = .empty,
    generation_id: std.ArrayList(u8) = .empty,
    resolved_model: std.ArrayList(u8) = .empty,
    failure_detail: ?[]u8 = null,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    created_at_s: i64 = 0,
    events: usize = 0,
    failed: bool = false,

    pub fn init(_: Allocator) Reducer {
        return .{};
    }

    pub fn deinit(self: *Reducer, alloc: Allocator) void {
        self.content.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        self.generation_id.deinit(alloc);
        self.resolved_model.deinit(alloc);
        if (self.failure_detail) |detail| alloc.free(detail);
        self.* = undefined;
    }

    /// Returns true when the stream is terminal and the caller should stop reading.
    pub fn applyJson(
        self: *Reducer,
        alloc: Allocator,
        json_text: []const u8,
        callbacks: StreamCallbacks,
        cancel_flag: *std.atomic.Value(bool),
        content_capture_limit: ?usize,
        limits: Limits,
    ) !bool {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        self.events += 1;
        if (self.events > max_stream_events) return error.ResourceLimitExceeded;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidEvent;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidEvent;
        const root = parsed.value.object;

        if (root.get("error")) |value| {
            try self.captureFailure(alloc, value);
            return true;
        }
        if (stringField(root, "id")) |id| {
            if (self.generation_id.items.len == 0 and id.len > 0 and id.len <= limits.generation_id_bytes) {
                try self.generation_id.appendSlice(alloc, id);
            }
        }
        if (stringField(root, "model")) |model| {
            if (self.resolved_model.items.len == 0 and model.len > 0 and model.len <= limits.generation_id_bytes) {
                try self.resolved_model.appendSlice(alloc, model);
            }
        }
        if (root.get("created")) |value| {
            if (value == .integer and value.integer > 0 and self.created_at_s == 0) {
                self.created_at_s = value.integer;
            }
        }
        if (root.get("usage")) |value| {
            if (value == .object) self.applyUsage(value.object);
        }

        const choices = root.get("choices") orelse return false;
        if (choices != .array) return error.InvalidEvent;
        if (choices.array.items.len > max_choices) return error.InvalidEvent;
        for (choices.array.items) |choice_value| {
            if (choice_value != .object) return error.InvalidEvent;
            const choice = choice_value.object;
            if (choice.get("delta")) |delta| {
                if (delta != .object) return error.InvalidEvent;
                try self.applyDelta(alloc, delta.object, callbacks, content_capture_limit, limits);
            }
            // Non-streaming servers answer a streaming request with a full
            // message. Treat it as one terminal delta rather than losing it.
            if (choice.get("message")) |message| {
                if (message != .object) return error.InvalidEvent;
                try self.applyDelta(alloc, message.object, callbacks, content_capture_limit, limits);
            }
            if (stringField(choice, "finish_reason")) |reason| {
                self.finish_reason = types.ProviderFinishReason.parse_legacy(reason) orelse .other;
            }
        }
        return false;
    }

    fn applyDelta(
        self: *Reducer,
        alloc: Allocator,
        delta: std.json.ObjectMap,
        callbacks: StreamCallbacks,
        content_capture_limit: ?usize,
        limits: Limits,
    ) !void {
        if (delta.get("content")) |value| switch (value) {
            .string => |text| try self.appendContent(alloc, text, callbacks, content_capture_limit, limits),
            // Some routers stream structured content parts instead of a string.
            .array => |parts| for (parts.items) |part| {
                if (part != .object) continue;
                const text = stringField(part.object, "text") orelse continue;
                try self.appendContent(alloc, text, callbacks, content_capture_limit, limits);
            },
            .null => {},
            else => return error.InvalidEvent,
        };
        if (reasoningDelta(delta)) |text| {
            if (text.len > 0) if (callbacks.on_reasoning) |emit| emit(callbacks.context, text);
        }
        const tool_calls = delta.get("tool_calls") orelse return;
        if (tool_calls != .array) return error.InvalidEvent;
        for (tool_calls.array.items) |call_value| {
            if (call_value != .object) return error.InvalidEvent;
            try self.applyToolCall(alloc, call_value.object, callbacks, limits);
        }
    }

    fn appendContent(
        self: *Reducer,
        alloc: Allocator,
        text: []const u8,
        callbacks: StreamCallbacks,
        content_capture_limit: ?usize,
        limits: Limits,
    ) !void {
        if (text.len == 0) return;
        callbacks.on_content(callbacks.context, text);
        const capture_limit = @min(content_capture_limit orelse limits.content_bytes, limits.content_bytes);
        const remaining = capture_limit -| self.content.items.len;
        if (remaining == 0) return;
        try self.content.appendSlice(alloc, text[0..@min(text.len, remaining)]);
    }

    fn applyToolCall(
        self: *Reducer,
        alloc: Allocator,
        call: std.json.ObjectMap,
        callbacks: StreamCallbacks,
        limits: Limits,
    ) !void {
        const index = blk: {
            const value = call.get("index") orelse break :blk @as(i64, @intCast(self.tools.items.len));
            if (value != .integer or value.integer < 0) return error.InvalidEvent;
            break :blk value.integer;
        };
        const slot = try self.toolSlot(alloc, index, limits);

        if (stringField(call, "id")) |id| {
            if (slot.id.items.len == 0 and id.len > 0) {
                if (id.len > limits.tool_identity_bytes) return error.ToolCallLimitExceeded;
                try slot.id.appendSlice(alloc, id);
            }
        }
        const function = call.get("function") orelse {
            try self.announce(slot, callbacks);
            return;
        };
        if (function != .object) return error.InvalidEvent;
        if (stringField(function.object, "name")) |name| {
            if (slot.name.items.len == 0 and name.len > 0) {
                if (name.len > limits.tool_identity_bytes) return error.ToolCallLimitExceeded;
                try slot.name.appendSlice(alloc, name);
            }
        }
        try self.announce(slot, callbacks);
        if (stringField(function.object, "arguments")) |chunk| {
            if (chunk.len > 0) {
                if (slot.arguments.items.len + chunk.len > limits.tool_arguments_bytes) {
                    return error.ToolArgumentsTooLarge;
                }
                try slot.arguments.appendSlice(alloc, chunk);
                if (callbacks.on_tool_input) |emit| emit(callbacks.context, chunk);
            }
        }
    }

    fn toolSlot(self: *Reducer, alloc: Allocator, index: i64, limits: Limits) !*ToolAccumulator {
        for (self.tools.items) |*tool| {
            if (tool.index == index) return tool;
        }
        if (self.tools.items.len >= limits.tool_calls) return error.ToolCallLimitExceeded;
        try self.tools.append(alloc, .{ .index = index });
        return &self.tools.items[self.tools.items.len - 1];
    }

    fn announce(self: *Reducer, slot: *ToolAccumulator, callbacks: StreamCallbacks) !void {
        _ = self;
        if (slot.announced or slot.name.items.len == 0) return;
        slot.announced = true;
        if (callbacks.on_tool_start) |emit| {
            emit(callbacks.context, slot.id.items, slot.name.items, null);
        }
    }

    fn applyUsage(self: *Reducer, usage: std.json.ObjectMap) void {
        self.usage.input_tokens = optionalCounter(usage, "prompt_tokens") orelse self.usage.input_tokens;
        self.usage.output_tokens = optionalCounter(usage, "completion_tokens") orelse self.usage.output_tokens;
        if (usage.get("prompt_tokens_details")) |details| if (details == .object) {
            self.usage.cache_read_tokens =
                optionalCounter(details.object, "cached_tokens") orelse self.usage.cache_read_tokens;
        };
        if (usage.get("completion_tokens_details")) |details| if (details == .object) {
            self.usage.reasoning_tokens =
                optionalCounter(details.object, "reasoning_tokens") orelse self.usage.reasoning_tokens;
        };
    }

    fn captureFailure(self: *Reducer, alloc: Allocator, value: std.json.Value) !void {
        self.failed = true;
        self.finish_reason = .provider_error;
        if (self.failure_detail != null) return;
        const message = switch (value) {
            .string => |text| text,
            .object => |object| stringField(object, "message") orelse "provider reported an error",
            else => "provider reported an error",
        };
        self.failure_detail = try alloc.dupe(u8, message[0..@min(message.len, max_failure_detail_bytes)]);
    }

    /// Takes ownership of the inline error message the endpoint streamed, when
    /// it streamed one. The caller frees it and must report it to the user:
    /// a router's own words are the most useful diagnostic fx can offer.
    pub fn takeFailureDetail(self: *Reducer) ?[]u8 {
        const detail = self.failure_detail orelse return null;
        self.failure_detail = null;
        return detail;
    }

    /// Produces the owned completion. The caller frees it through
    /// `stream_provider.Result.deinit` with `ownership = .owned`.
    pub fn finish(
        self: *Reducer,
        alloc: Allocator,
        cancel_flag: *std.atomic.Value(bool),
    ) !types.ModelCompletion {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (self.failed) return error.CompatResponseFailed;

        var completion = types.ModelCompletion{ .usage = self.usage };
        errdefer freeCompletion(alloc, &completion);

        if (self.content.items.len > 0) {
            completion.content = try alloc.dupe(u8, self.content.items);
        }
        if (self.generation_id.items.len > 0) {
            completion.generation_id = try alloc.dupe(u8, self.generation_id.items);
        }
        completion.tool_calls = try self.takeToolCalls(alloc);
        completion.finish_reason = self.finish_reason orelse
            if (completion.tool_calls.len > 0) .tool_calls else .stop;
        return completion;
    }

    fn takeToolCalls(self: *Reducer, alloc: Allocator) ![]const types.ToolCall {
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer types.freeToolCallSlice(alloc, calls.items);
        errdefer calls.deinit(alloc);

        for (self.tools.items, 0..) |*tool, position| {
            if (tool.name.items.len == 0) continue;
            const id = if (tool.id.items.len > 0)
                try alloc.dupe(u8, tool.id.items)
            else
                try std.fmt.allocPrint(alloc, "call_{d}", .{position});
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, tool.name.items);
            errdefer alloc.free(name);
            const arguments = try alloc.dupe(
                u8,
                if (tool.arguments.items.len > 0) tool.arguments.items else "{}",
            );
            errdefer alloc.free(arguments);
            try calls.append(alloc, .{
                .id = id,
                .name = name,
                .arguments_json = arguments,
                .argument_integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, arguments),
            });
        }
        return calls.toOwnedSlice(alloc);
    }
};

fn freeCompletion(alloc: Allocator, completion: *types.ModelCompletion) void {
    if (completion.content) |content| alloc.free(@constCast(content));
    if (completion.generation_id) |id| alloc.free(@constCast(id));
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    completion.* = .{};
}

/// Routers spell the reasoning delta either way; both carry the same text.
fn reasoningDelta(delta: std.json.ObjectMap) ?[]const u8 {
    if (stringField(delta, "reasoning_content")) |text| return text;
    if (stringField(delta, "reasoning")) |text| return text;
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn optionalCounter(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

const max_stream_events: usize = 100_000;
const max_choices: usize = 8;
const max_failure_detail_bytes: usize = 4096;

const test_limits = Limits{
    .tool_calls = 128,
    .tool_identity_bytes = 1024,
    .tool_arguments_bytes = 4 * 1024 * 1024,
    .content_bytes = 4 * 1024 * 1024,
    .generation_id_bytes = 256,
};

test "compat request serializes messages, tools, and tool results" {
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read",
        .input_schema = .{},
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildRequest(std.testing.allocator, .{
        .model = "anthropic/claude-opus-4.6",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .max_output_tokens = 4096,
    }, test_limits);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"anthropic/claude-opus-4.6\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"system\",\"content\":\"Be concise.\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"user\",\"content\":\"Read it.\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"contents\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":4096") != null);
}

test "compat request omits tool fields when no tool is advertised" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "openai/gpt-5",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    }, test_limits);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\"") == null);
}

test "compat request attaches verified images to the final user message once" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "openai/gpt-5",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
        .verified_images = &images,
    }, test_limits);
    defer std.testing.allocator.free(body);

    const marker = "\"type\":\"image_url\"";
    const first = std.mem.find(u8, body, marker) orelse return error.TestExpectedImage;
    try std.testing.expect(std.mem.findPos(u8, body, first + marker.len, marker) == null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"type\":\"text\",\"text\":\"Describe it.\"}") != null);
}

test "compat request rejects a model that cannot sit in a request line" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    try std.testing.expectError(error.InvalidCompatModel, buildRequest(std.testing.allocator, .{
        .model = "bad model\nid",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    }, test_limits));
}

const Capture = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    started: std.ArrayList(u8) = .empty,

    fn deinit(self: *Capture) void {
        self.content.deinit(std.testing.allocator);
        self.reasoning.deinit(std.testing.allocator);
        self.tool_input.deinit(std.testing.allocator);
        self.started.deinit(std.testing.allocator);
    }

    fn onContent(raw: *anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
    }

    fn onReasoning(raw: *anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.reasoning.appendSlice(std.testing.allocator, chunk) catch unreachable;
    }

    fn onToolInput(raw: *anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.tool_input.appendSlice(std.testing.allocator, chunk) catch unreachable;
    }

    fn onToolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.started.appendSlice(std.testing.allocator, name) catch unreachable;
    }

    fn callbacks(self: *Capture) StreamCallbacks {
        return .{
            .context = self,
            .on_content = onContent,
            .on_tool_start = onToolStart,
            .on_reasoning = onReasoning,
            .on_tool_input = onToolInput,
        };
    }
};

fn reduceForTest(
    alloc: Allocator,
    capture: *Capture,
    events: []const []const u8,
) !types.ModelCompletion {
    var cancelled = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init(alloc);
    defer reducer.deinit(alloc);
    for (events) |event| {
        if (try reducer.applyJson(alloc, event, capture.callbacks(), &cancelled, null, test_limits)) break;
    }
    return reducer.finish(alloc, &cancelled);
}

test "compat stream reduces text, reasoning, tool calls, and usage" {
    var capture: Capture = .{};
    defer capture.deinit();

    const completion = try reduceForTest(std.testing.allocator, &capture, &.{
        "{\"id\":\"gen-1\",\"model\":\"anthropic/claude-opus-4.6\",\"created\":1730000000,\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}",
        "{\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"thinking\"}}]}",
        "{\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello \"}}]}",
        "{\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"world\"}}]}",
        "{\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}",
        "{\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}",
        "{\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
        "{\"id\":\"gen-1\",\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":4},\"completion_tokens_details\":{\"reasoning_tokens\":3}}}",
    });
    defer {
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("hello world", completion.content.?);
    try std.testing.expectEqualStrings("hello world", capture.content.items);
    try std.testing.expectEqualStrings("thinking", capture.reasoning.items);
    try std.testing.expectEqualStrings("read_file", capture.started.items);
    try std.testing.expectEqualStrings("gen-1", completion.generation_id.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_a", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, completion.tool_calls[0].argument_integrity);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 12), completion.usage.input_tokens.?);
    try std.testing.expectEqual(@as(u64, 5), completion.usage.output_tokens.?);
    try std.testing.expectEqual(@as(u64, 4), completion.usage.cache_read_tokens.?);
    try std.testing.expectEqual(@as(u64, 3), completion.usage.reasoning_tokens.?);
}

test "compat stream accepts a non-streaming message body and the reasoning alias" {
    var capture: Capture = .{};
    defer capture.deinit();

    const completion = try reduceForTest(std.testing.allocator, &capture, &.{
        "{\"id\":\"gen-2\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"pondering\"}}]}",
        "{\"id\":\"gen-2\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"done\"},\"finish_reason\":\"stop\"}]}",
    });
    defer {
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("done", completion.content.?);
    try std.testing.expectEqualStrings("pondering", capture.reasoning.items);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 0), completion.tool_calls.len);
}

test "compat stream synthesizes a tool call id when the router omits one" {
    var capture: Capture = .{};
    defer capture.deinit();

    const completion = try reduceForTest(std.testing.allocator, &capture, &.{
        "{\"id\":\"gen-3\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"list_dir\"}}]}}]}",
    });
    defer {
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_0", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "compat stream surfaces an inline provider error as a failed response" {
    var capture: Capture = .{};
    defer capture.deinit();

    try std.testing.expectError(error.CompatResponseFailed, reduceForTest(std.testing.allocator, &capture, &.{
        "{\"id\":\"gen-4\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}",
        "{\"error\":{\"message\":\"upstream model is overloaded\",\"code\":502}}",
    }));
}

test "compat stream enforces the tool argument budget" {
    var capture: Capture = .{};
    defer capture.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init(std.testing.allocator);
    defer reducer.deinit(std.testing.allocator);

    const tight = Limits{
        .tool_calls = 1,
        .tool_identity_bytes = 32,
        .tool_arguments_bytes = 4,
        .content_bytes = 1024,
        .generation_id_bytes = 64,
    };
    try std.testing.expectError(error.ToolArgumentsTooLarge, reducer.applyJson(
        std.testing.allocator,
        "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"t\",\"arguments\":\"0123456789\"}}]}}]}",
        capture.callbacks(),
        &cancelled,
        null,
        tight,
    ));
}
