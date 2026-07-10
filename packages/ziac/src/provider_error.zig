const std = @import("std");
const fx = @import("zigeffect_std").fx;

pub const ProviderError = error{
    AuthenticationFailed,
    AuthorizationFailed,
    InvalidConfiguration,
    Conflict,
    NotFound,
    QuotaExceeded,
    RateLimited,
    TransientFailure,
    ProviderTimeout,
    ProviderCancelled,
    RemoteOperationFailed,
    DestructiveConfirmationRequired,
    ProviderBug,
    OutOfMemory,
};

pub const Category = enum {
    authentication,
    authorization,
    invalid_configuration,
    conflict,
    not_found,
    quota,
    rate_limited,
    transient,
    timeout,
    cancelled,
    remote_operation,
    provider_bug,
};

pub fn category(err: ProviderError) Category {
    return switch (err) {
        error.AuthenticationFailed => .authentication,
        error.AuthorizationFailed => .authorization,
        error.InvalidConfiguration => .invalid_configuration,
        error.Conflict => .conflict,
        error.NotFound => .not_found,
        error.QuotaExceeded => .quota,
        error.RateLimited => .rate_limited,
        error.TransientFailure => .transient,
        error.ProviderTimeout => .timeout,
        error.ProviderCancelled => .cancelled,
        error.RemoteOperationFailed => .remote_operation,
        error.DestructiveConfirmationRequired => .invalid_configuration,
        error.ProviderBug, error.OutOfMemory => .provider_bug,
    };
}

pub const DiagnosticSource = struct {
    category: Category,
    service: ?[]const u8 = null,
    status: ?u16 = null,
    google_status: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    retry_after_millis: ?u64 = null,
    quota_metric: ?[]const u8 = null,
    quota_limit: ?[]const u8 = null,
    quota_subject: ?[]const u8 = null,
};

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    category: Category,
    service: ?[]const u8 = null,
    status: ?u16 = null,
    google_status: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    retry_after_millis: ?u64 = null,
    quota_metric: ?[]const u8 = null,
    quota_limit: ?[]const u8 = null,
    quota_subject: ?[]const u8 = null,

    pub fn initOwned(allocator: std.mem.Allocator, input: DiagnosticSource) std.mem.Allocator.Error!Diagnostic {
        var diagnostic = Diagnostic{ .allocator = allocator, .category = input.category };
        errdefer diagnostic.deinit();
        diagnostic.service = try cloneOptionalBounded(allocator, input.service);
        diagnostic.status = input.status;
        diagnostic.google_status = try cloneOptionalBounded(allocator, input.google_status);
        diagnostic.request_id = try cloneOptionalBounded(allocator, input.request_id);
        diagnostic.message = try cloneOptionalBounded(allocator, input.message);
        diagnostic.retry_after_millis = input.retry_after_millis;
        diagnostic.quota_metric = try cloneOptionalBounded(allocator, input.quota_metric);
        diagnostic.quota_limit = try cloneOptionalBounded(allocator, input.quota_limit);
        diagnostic.quota_subject = try cloneOptionalBounded(allocator, input.quota_subject);
        return diagnostic;
    }

    pub fn clone(self: Diagnostic, allocator: std.mem.Allocator) std.mem.Allocator.Error!Diagnostic {
        return initOwned(allocator, self.toSource());
    }

    pub fn deinit(self: *Diagnostic) void {
        freeOptional(self.allocator, self.service);
        freeOptional(self.allocator, self.google_status);
        freeOptional(self.allocator, self.request_id);
        freeOptional(self.allocator, self.message);
        freeOptional(self.allocator, self.quota_metric);
        freeOptional(self.allocator, self.quota_limit);
        freeOptional(self.allocator, self.quota_subject);
        self.* = undefined;
    }

    pub fn formatAlloc(self: Diagnostic, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var bytes = std.ArrayList(u8).empty;
        errdefer bytes.deinit(allocator);
        try bytes.print(allocator, "category={s}", .{@tagName(self.category)});
        if (self.service) |text| try bytes.print(allocator, " service={s}", .{text});
        if (self.status) |number| try bytes.print(allocator, " status={d}", .{number});
        if (self.google_status) |text| try bytes.print(allocator, " google_status={s}", .{text});
        if (self.request_id) |text| try bytes.print(allocator, " request_id={s}", .{text});
        if (self.retry_after_millis) |number| try bytes.print(allocator, " retry_after_ms={d}", .{number});
        if (self.quota_metric) |text| try bytes.print(allocator, " quota_metric={s}", .{text});
        if (self.quota_limit) |text| try bytes.print(allocator, " quota_limit={s}", .{text});
        if (self.quota_subject) |text| try bytes.print(allocator, " quota_subject={s}", .{text});
        if (self.message) |text| try bytes.print(allocator, " message={s}", .{text});
        return bytes.toOwnedSlice(allocator);
    }

    fn toSource(self: Diagnostic) DiagnosticSource {
        return .{
            .category = self.category,
            .service = self.service,
            .status = self.status,
            .google_status = self.google_status,
            .request_id = self.request_id,
            .message = self.message,
            .retry_after_millis = self.retry_after_millis,
            .quota_metric = self.quota_metric,
            .quota_limit = self.quota_limit,
            .quota_subject = self.quota_subject,
        };
    }
};

pub const DiagnosticRecorder = struct {
    allocator: std.mem.Allocator,
    mutex: fx.SpinLock = .{},
    latest: ?Diagnostic = null,

    pub fn init(allocator: std.mem.Allocator) DiagnosticRecorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DiagnosticRecorder) void {
        self.mutex.lock();
        if (self.latest) |*diagnostic| diagnostic.deinit();
        self.latest = null;
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn record(self: *DiagnosticRecorder, source: DiagnosticSource) std.mem.Allocator.Error!void {
        const owned = try Diagnostic.initOwned(self.allocator, source);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.latest) |*diagnostic| diagnostic.deinit();
        self.latest = owned;
    }

    pub fn snapshotAlloc(
        self: *DiagnosticRecorder,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!?Diagnostic {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.latest) |diagnostic| try diagnostic.clone(allocator) else null;
    }
};

const max_diagnostic_field_bytes = 512;

fn cloneOptionalBounded(
    allocator: std.mem.Allocator,
    source: ?[]const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const text = source orelse return null;
    const owned = try allocator.dupe(u8, text[0..@min(text.len, max_diagnostic_field_bytes)]);
    for (owned) |*character| {
        if (character.* < 0x20 or character.* == 0x7f) character.* = ' ';
    }
    const sanitized: []const u8 = owned;
    return sanitized;
}

fn freeOptional(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |text| allocator.free(text);
}
