const std = @import("std");
const zstd = @import("zigeffect_std");
const client = @import("client.zig");
const value = @import("../value.zig");

pub const ValidationError = error{
    MissingApiKeyReference,
    UnsupportedSecretProvider,
    InvalidApiKeyReference,
    MissingBaseUrl,
};

pub fn environmentApiKey(name: []const u8) value.SecretReference {
    return .{ .provider = "env", .resource = name };
}

pub const ProviderConfig = struct {
    api_key: value.SecretReference = environmentApiKey("COCKROACH_API_KEY"),
    base_url: []const u8 = client.default_base_url,

    pub fn validate(self: ProviderConfig) ValidationError!void {
        if (!std.mem.eql(u8, self.api_key.provider, "env")) return error.UnsupportedSecretProvider;
        if (self.api_key.resource.len == 0) return error.MissingApiKeyReference;
        if (self.api_key.version != null or self.api_key.field != null) return error.InvalidApiKeyReference;
        if (self.base_url.len == 0) return error.MissingBaseUrl;
    }

    pub fn apiKeyInput(self: ProviderConfig) value.Value {
        return .{ .secret_ref = self.api_key };
    }

    pub fn loadApiKeyAlloc(
        self: ProviderConfig,
        allocator: std.mem.Allocator,
        env: zstd.Env.EnvMap,
    ) (ValidationError || std.mem.Allocator.Error || error{MissingApiKey})!client.ApiKey {
        try self.validate();
        return client.ApiKey.fromEnvAlloc(allocator, env, self.api_key.resource);
    }
};
