const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const authorized_user_json = @embedFile("fixtures/gcp/authorized_user.json");
const service_account_json = @embedFile("fixtures/gcp/service_account.json");
const external_account_json = @embedFile("fixtures/gcp/external_account.json");
const external_account_url_json = @embedFile("fixtures/gcp/external_account_url.json");

test "GCP ADC follows environment well-known file metadata order" {
    var files = zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer files.deinit();
    try files.writeFile("/explicit.json", service_account_json);
    try files.writeFile("/home/test/.config/gcloud/application_default_credentials.json", authorized_user_json);

    var explicit_env = zstd.Env.EnvMap.init(std.testing.allocator);
    defer explicit_env.deinit();
    try explicit_env.put("HOME", "/home/test");
    try explicit_env.put("GOOGLE_APPLICATION_CREDENTIALS", "/explicit.json");

    var explicit = try auth.resolveAdcAlloc(std.testing.allocator, explicit_env, &files);
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqual(auth.SourceLocation.environment, explicit.location);
    try std.testing.expectEqual(auth.CredentialKind.service_account, explicit.credentialKind().?);

    var local_env = zstd.Env.EnvMap.init(std.testing.allocator);
    defer local_env.deinit();
    try local_env.put("HOME", "/home/test");
    var well_known = try auth.resolveAdcAlloc(std.testing.allocator, local_env, &files);
    defer well_known.deinit(std.testing.allocator);
    try std.testing.expectEqual(auth.SourceLocation.well_known_file, well_known.location);
    try std.testing.expectEqual(auth.CredentialKind.authorized_user, well_known.credentialKind().?);

    files.deleteFile("/home/test/.config/gcloud/application_default_credentials.json");
    var metadata = try auth.resolveAdcAlloc(std.testing.allocator, local_env, &files);
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqual(auth.SourceLocation.metadata, metadata.location);
    try std.testing.expect(metadata.credentialKind() == null);
}

test "GCP ADC explicit missing credential file is a hard failure" {
    var files = zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer files.deinit();
    var env = zstd.Env.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GOOGLE_APPLICATION_CREDENTIALS", "/missing.json");

    try std.testing.expectError(
        error.CredentialFileNotFound,
        auth.resolveAdcAlloc(std.testing.allocator, env, &files),
    );
}

test "GCP authorized-user refresh exchange is form encoded" {
    var credential = try auth.decodeCredentialAlloc(std.testing.allocator, authorized_user_json);
    defer credential.deinit(std.testing.allocator);

    var request = try auth.authorizedUserRequestAlloc(std.testing.allocator, credential.authorized_user);
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("POST", request.request.method);
    try std.testing.expectEqualStrings(auth.google_token_endpoint, request.request.url);
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", request.request.headers[0].value);
    try std.testing.expectEqualStrings(
        "client_id=dummy-client.apps.googleusercontent.com&client_secret=dummy-client-secret&refresh_token=dummy-refresh-token&grant_type=refresh_token",
        request.request.body,
    );
}

const DummySigner = struct {
    calls: usize = 0,
    saw_signing_input: bool = false,

    fn signer(self: *DummySigner) auth.Signer {
        return .{ .ptr = self, .signFn = sign };
    }

    fn sign(raw: *anyopaque, allocator: std.mem.Allocator, message: []const u8) auth.AuthError![]const u8 {
        const self: *DummySigner = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.saw_signing_input = std.mem.count(u8, message, ".") == 1;
        return allocator.dupe(u8, "dummy-signature");
    }
};

test "GCP service-account assertion has RS256 header claims and signature" {
    var credential = try auth.decodeCredentialAlloc(std.testing.allocator, service_account_json);
    defer credential.deinit(std.testing.allocator);
    var signer = DummySigner{};

    var request = try auth.serviceAccountRequestAlloc(
        std.testing.allocator,
        credential.service_account,
        auth.cloud_platform_scope,
        1_700_000_000,
        signer.signer(),
    );
    defer request.deinit(std.testing.allocator);

    const assertion = formValue(request.request.body, "assertion").?;
    var parts = std.mem.splitScalar(u8, assertion, '.');
    const header = try decodeBase64UrlAlloc(std.testing.allocator, parts.next().?);
    defer std.testing.allocator.free(header);
    const claims = try decodeBase64UrlAlloc(std.testing.allocator, parts.next().?);
    defer std.testing.allocator.free(claims);
    const signature = try decodeBase64UrlAlloc(std.testing.allocator, parts.next().?);
    defer std.testing.allocator.free(signature);
    try std.testing.expect(parts.next() == null);

    try expectJsonString(header, "alg", "RS256");
    try expectJsonString(header, "typ", "JWT");
    try expectJsonString(header, "kid", "dummy-key-id");
    try expectJsonString(claims, "iss", "dummy-service@dummy-project.iam.gserviceaccount.com");
    try expectJsonString(claims, "scope", auth.cloud_platform_scope);
    try expectJsonString(claims, "aud", auth.google_token_endpoint);
    try expectJsonInteger(claims, "iat", 1_700_000_000);
    try expectJsonInteger(claims, "exp", 1_700_003_600);
    try std.testing.expectEqualStrings("dummy-signature", signature);
    try std.testing.expectEqual(@as(usize, 1), signer.calls);
    try std.testing.expect(signer.saw_signing_input);
    try std.testing.expect(std.mem.indexOf(
        u8,
        request.request.body,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer",
    ) != null);
}

test "GCP native service-account signer produces verifiable RS256 signatures" {
    var credential = try auth.decodeCredentialAlloc(std.testing.allocator, service_account_json);
    defer credential.deinit(std.testing.allocator);
    var native_signer = auth.RsaSigner.init(credential.service_account.private_key);

    const signature = try native_signer.signer().signAlloc(std.testing.allocator, "ziac-rs256-contract");
    defer std.testing.allocator.free(signature);

    try std.testing.expectEqual(@as(usize, 256), signature.len);
    try native_signer.verify("ziac-rs256-contract", signature);
    try std.testing.expectError(error.InvalidSignature, native_signer.verify("changed", signature));
}

test "GCP external-account exchange uses RFC 8693 fields" {
    var credential = try auth.decodeCredentialAlloc(std.testing.allocator, external_account_json);
    defer credential.deinit(std.testing.allocator);

    var request = try auth.externalAccountRequestAlloc(
        std.testing.allocator,
        credential.external_account,
        "dummy-subject-token",
        auth.cloud_platform_scope,
    );
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://sts.googleapis.com/v1/token", request.request.url);
    try std.testing.expectEqualStrings(
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange" ++
            "&audience=%2F%2Fiam.googleapis.com%2Fprojects%2F123456%2Flocations%2Fglobal%2FworkloadIdentityPools%2Fdummy-pool%2Fproviders%2Fdummy-provider" ++
            "&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform" ++
            "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token" ++
            "&subject_token=dummy-subject-token" ++
            "&subject_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Ajwt",
        request.request.body,
    );
}

test "GCP external-account subject tokens load from files" {
    var files = zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer files.deinit();
    try files.writeFile("/var/run/ziac/dummy-oidc-token", "  dummy-file-subject\n");
    const reader = auth.memoryFileReader(&files);
    var source = auth.FileSubjectTokenSource.init(reader, "/var/run/ziac/dummy-oidc-token", .text);

    const token = try source.fetchAlloc(std.testing.allocator);
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("dummy-file-subject", token);
}

test "GCP external-account URL source preserves headers and extracts JSON token" {
    var credential = try auth.decodeCredentialAlloc(std.testing.allocator, external_account_url_json);
    defer credential.deinit(std.testing.allocator);
    var recording = SubjectRecordingTransport{};
    var source = auth.UrlSubjectTokenSource.init(recording.client(), &credential.external_account.credential_source);

    const token = try source.fetchAlloc(std.testing.allocator);
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("dummy-url-subject", token);
    try std.testing.expect(recording.saw_authorization);
}

test "GCP external-account source exchanges STS token for impersonated service account token" {
    var credential = try auth.decodeCredentialAlloc(std.testing.allocator, external_account_url_json);
    defer credential.deinit(std.testing.allocator);
    var subject = StaticSubjectTokenSource{};
    var transport = ImpersonationTransport{};
    var source = auth.ExternalAccountTokenSource{
        .client = transport.client(),
        .credential = &credential.external_account,
        .subject_source = subject.subjectTokenSource(),
    };

    var token = try source.fetchAlloc(std.testing.allocator, 1_700_000_000);
    defer token.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dummy-impersonated-token", token.access_token);
    try std.testing.expectEqual(@as(u64, 1_700_003_600), token.expires_at_seconds);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expect(transport.saw_sts_request);
    try std.testing.expect(transport.saw_impersonation_request);
}

const StaticSubjectTokenSource = struct {
    fn subjectTokenSource(self: *StaticSubjectTokenSource) auth.SubjectTokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator) auth.AuthError![]const u8 {
        return allocator.dupe(u8, "dummy-subject-token");
    }
};

const ImpersonationTransport = struct {
    calls: usize = 0,
    saw_sts_request: bool = false,
    saw_impersonation_request: bool = false,

    fn client(self: *ImpersonationTransport) zstd.Http.Client {
        return .{ .ptr = self, .sendFn = send };
    }

    fn send(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        request: zstd.Http.Request,
        options: zstd.Http.SendOptions,
    ) zstd.Http.ClientError!zstd.Http.Response {
        const self: *ImpersonationTransport = @ptrCast(@alignCast(raw));
        try options.checkActive();
        self.calls += 1;
        if (self.calls == 1) {
            self.saw_sts_request = std.mem.eql(u8, request.url, "https://sts.googleapis.com/v1/token") and
                std.mem.indexOf(u8, request.body, "subject_token=dummy-subject-token") != null;
            return zstd.Http.cloneResponseAlloc(allocator, .{
                .status = 200,
                .body = "{\"access_token\":\"dummy-sts-token\",\"expires_in\":600,\"token_type\":\"Bearer\"}",
            });
        }

        const authorization = for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) break header.value;
        } else "";
        self.saw_impersonation_request = std.mem.eql(
            u8,
            request.url,
            "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/dummy-service@dummy-project.iam.gserviceaccount.com:generateAccessToken",
        ) and std.mem.eql(u8, authorization, "Bearer dummy-sts-token") and
            std.mem.eql(u8, request.body, "{\"scope\":[\"https://www.googleapis.com/auth/cloud-platform\"],\"lifetime\":\"3600s\"}");
        return zstd.Http.cloneResponseAlloc(allocator, .{
            .status = 200,
            .body = "{\"accessToken\":\"dummy-impersonated-token\",\"expireTime\":\"2023-11-14T23:13:20Z\"}",
        });
    }
};

const SubjectRecordingTransport = struct {
    saw_authorization: bool = false,

    fn client(self: *SubjectRecordingTransport) zstd.Http.Client {
        return .{ .ptr = self, .sendFn = send };
    }

    fn send(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        request: zstd.Http.Request,
        options: zstd.Http.SendOptions,
    ) zstd.Http.ClientError!zstd.Http.Response {
        const self: *SubjectRecordingTransport = @ptrCast(@alignCast(raw));
        try options.checkActive();
        self.saw_authorization = request.headers.len == 1 and
            std.ascii.eqlIgnoreCase(request.headers[0].name, "Authorization") and
            std.mem.eql(u8, request.headers[0].value, "Bearer dummy-source-authorization");
        return zstd.Http.cloneResponseAlloc(allocator, .{
            .status = 200,
            .body = "{\"value\":\"dummy-url-subject\"}",
        });
    }
};

const RecordingTransport = struct {
    calls: usize = 0,
    saw_metadata_header: bool = false,

    fn client(self: *RecordingTransport) zstd.Http.Client {
        return .{ .ptr = self, .sendFn = send };
    }

    fn send(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        request: zstd.Http.Request,
        options: zstd.Http.SendOptions,
    ) zstd.Http.ClientError!zstd.Http.Response {
        const self: *RecordingTransport = @ptrCast(@alignCast(raw));
        try options.checkActive();
        self.calls += 1;
        self.saw_metadata_header = request.headers.len == 1 and
            std.ascii.eqlIgnoreCase(request.headers[0].name, "Metadata-Flavor") and
            std.mem.eql(u8, request.headers[0].value, "Google");
        return zstd.Http.cloneResponseAlloc(allocator, .{
            .status = 200,
            .body = "{\"access_token\":\"dummy-metadata-token\",\"expires_in\":3599,\"token_type\":\"Bearer\"}",
        });
    }
};

test "GCP metadata source sends required header and parses expiry" {
    var recording = RecordingTransport{};
    var source = auth.MetadataTokenSource.init(recording.client());
    var token = try source.fetchAlloc(std.testing.allocator, 10_000);
    defer token.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expect(recording.saw_metadata_header);
    try std.testing.expectEqualStrings("dummy-metadata-token", token.access_token);
    try std.testing.expectEqualStrings("Bearer", token.token_type);
    try std.testing.expectEqual(@as(u64, 13_599), token.expires_at_seconds);
}

const CountingTokenSource = struct {
    calls: usize = 0,

    fn tokenSource(self: *CountingTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(raw: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        const self: *CountingTokenSource = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = if (self.calls == 1) "dummy-token-one" else "dummy-token-two",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 600,
        });
    }
};

test "GCP token cache refreshes before expiry and owns returned tokens" {
    var counting = CountingTokenSource{};
    var cache = auth.TokenCache.init(counting.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);

    var first = try cache.getAlloc(std.testing.allocator, 1_000);
    defer first.deinit(std.testing.allocator);
    var cached = try cache.getAlloc(std.testing.allocator, 1_299);
    defer cached.deinit(std.testing.allocator);
    var refreshed = try cache.getAlloc(std.testing.allocator, 1_301);
    defer refreshed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dummy-token-one", first.access_token);
    try std.testing.expectEqualStrings("dummy-token-one", cached.access_token);
    try std.testing.expectEqualStrings("dummy-token-two", refreshed.access_token);
    try std.testing.expectEqual(@as(usize, 2), counting.calls);
}

test "resolved ADC token source dispatches authorized user credentials" {
    const responses = [_]zstd.Http.Response{.{
        .status = 200,
        .body = "{\"access_token\":\"dummy-adc-token\",\"expires_in\":3599,\"token_type\":\"Bearer\"}",
    }};
    var transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var files = zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer files.deinit();
    var resolved = auth.ResolvedAdc{
        .location = .environment,
        .credential = try auth.decodeCredentialAlloc(std.testing.allocator, authorized_user_json),
    };
    defer resolved.deinit(std.testing.allocator);
    var source = auth.AdcTokenSource.init(
        &resolved,
        transport.client(),
        auth.memoryFileReader(&files),
    );

    var token = try source.tokenSource().fetchAlloc(std.testing.allocator, 10_000);
    defer token.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dummy-adc-token", token.access_token);
    try std.testing.expectEqual(@as(usize, 1), transport.requests.items.len);
    try std.testing.expectEqualStrings(auth.google_token_endpoint, transport.requests.items[0].url);
}

test "GCP auth doctor identifies source without exposing credentials" {
    var files = zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer files.deinit();
    try files.writeFile("/explicit.json", authorized_user_json);
    var env = zstd.Env.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GOOGLE_APPLICATION_CREDENTIALS", "/explicit.json");

    var resolved = try auth.resolveAdcAlloc(std.testing.allocator, env, &files);
    defer resolved.deinit(std.testing.allocator);
    const diagnostic = try resolved.doctorJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(diagnostic);

    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "environment") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "authorized_user") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "dummy-client-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "dummy-refresh-token") == null);
}

fn formValue(body: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], name)) return pair[equals + 1 ..];
    }
    return null;
}

fn decodeBase64UrlAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded);
    return decoded;
}

fn expectJsonString(json: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(expected, parsed.value.object.get(field).?.string);
}

fn expectJsonInteger(json: []const u8, field: []const u8, expected: i64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(expected, parsed.value.object.get(field).?.integer);
}
