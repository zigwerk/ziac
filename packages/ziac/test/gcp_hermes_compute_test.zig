const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

const startup_digest = ziac.gcp.hermes_compute.reviewed_startup_script_sha256;

test "HermesCompute compiles a low-cost OAuth-gated desktop backend" {
    var deployment = try ziac.gcp.HermesCompute.build(std.testing.allocator, provider, baseArgs());
    defer deployment.deinit();

    try std.testing.expectEqual(@as(usize, 12), deployment.graph.resources.items.len);
    for (deployment.graph.resources.items) |node| try std.testing.expect(node.lifecycle.protect);

    const network = findType(&deployment.graph, "gcp.compute.Network");
    const subnet = findType(&deployment.graph, "gcp.compute.Subnetwork");
    const iap_firewall = findIdContaining(&deployment.graph, "gcp.compute.Firewall", "iap-ssh");
    const desktop_firewall = findIdContaining(&deployment.graph, "gcp.compute.Firewall", "desktop-edge");
    const address = findType(&deployment.graph, "gcp.compute.RegionalAddress");
    const account = findType(&deployment.graph, "gcp.iam.ServiceAccount");
    const secret = findType(&deployment.graph, "gcp.secret.Secret");
    const version = findType(&deployment.graph, "gcp.secret.SecretVersion");
    const access = findType(&deployment.graph, "gcp.secret.SecretIamMember");
    const disk = findType(&deployment.graph, "gcp.compute.Disk");
    const instance = findType(&deployment.graph, "gcp.compute.Instance");
    const record = findType(&deployment.graph, "gcp.dns.RecordSet");

    try expectString(input(instance, "machine_type"), "e2-medium");
    try expectString(input(disk, "disk_type"), "pd-balanced");
    try expectInteger(input(disk, "size_gb"), 30);
    try std.testing.expect(disk.lifecycle.protect);
    try std.testing.expect(disk.lifecycle.retain_on_delete);
    try std.testing.expect(instance.lifecycle.protect);
    try expectBoolean(input(instance, "deletion_protection"), true);
    const network_interface = firstListItem(input(instance, "network_interfaces"));
    try expectBoolean(nestedField(network_interface, "external_access"), true);
    try expectOutputReference(nestedField(network_interface, "external_ip"), address.id, "address");
    try expectMetadata(instance, "enable-oslogin", "TRUE");
    try expectMetadata(instance, "block-project-ssh-keys", "TRUE");
    try expectMetadata(instance, "hermes-image", "nousresearch/hermes-agent:v0.18.2");
    try expectMetadata(instance, "hermes-proxy-image", "caddy:2.11.4-alpine");
    try expectMetadata(instance, "hermes-env-secret", "projects/ziac-dev/secrets/hermes-env/versions/latest");
    try expectMetadata(instance, "hermes-domain", "hermes.example.com");
    try expectMetadata(instance, "hermes-oauth-client-id", "agent:ziac-hermes-test");
    try std.testing.expect(containsString(input(instance, "tags"), "hermes-desktop"));

    try expectString(input(iap_firewall, "direction"), "INGRESS");
    try expectString(input(iap_firewall, "action"), "ALLOW");
    try expectString(firstListItem(input(iap_firewall, "source_ranges")), "35.235.240.0/20");
    try expectString(firstListItem(input(iap_firewall, "target_tags")), "hermes-iap");
    const iap_rule = firstListItem(input(iap_firewall, "rules"));
    try expectString(nestedField(iap_rule, "protocol"), "tcp");
    try expectString(firstListItem(nestedField(iap_rule, "ports")), "22");

    try expectString(firstListItem(input(desktop_firewall, "source_ranges")), "0.0.0.0/0");
    try expectString(firstListItem(input(desktop_firewall, "target_tags")), "hermes-desktop");
    const desktop_rule = firstListItem(input(desktop_firewall, "rules"));
    try expectString(nestedField(desktop_rule, "protocol"), "tcp");
    try std.testing.expect(containsExactString(nestedField(desktop_rule, "ports"), "80"));
    try std.testing.expect(containsExactString(nestedField(desktop_rule, "ports"), "443"));
    try std.testing.expect(!containsString(desktop_firewall.inputs, "8642"));
    try std.testing.expect(!containsString(desktop_firewall.inputs, "9119"));

    try expectString(input(address, "region"), "europe-west1");
    try expectString(input(record, "name"), "hermes.example.com.");
    try expectString(input(record, "zone"), "example-com");
    try expectString(input(record, "type"), "A");
    try expectOutputReference(firstListItem(input(record, "rrdatas")), address.id, "address");

    try expectString(input(access, "role"), "roles/secretmanager.secretAccessor");
    try expectString(input(access, "member"), "serviceAccount:hermes@ziac-dev.iam.gserviceaccount.com");
    try std.testing.expect(input(version, "source") == .secret_ref);
    try std.testing.expect(input(instance, "startup_script") == .secret_ref);

    try std.testing.expect(hasDependency(&deployment.graph, subnet.id, network.id));
    try std.testing.expect(hasDependency(&deployment.graph, iap_firewall.id, network.id));
    try std.testing.expect(hasDependency(&deployment.graph, desktop_firewall.id, network.id));
    try std.testing.expect(hasDependency(&deployment.graph, version.id, secret.id));
    try std.testing.expect(hasDependency(&deployment.graph, access.id, secret.id));
    try std.testing.expect(hasDependency(&deployment.graph, access.id, account.id));
    try std.testing.expect(hasDependency(&deployment.graph, instance.id, disk.id));
    try std.testing.expect(hasDependency(&deployment.graph, instance.id, subnet.id));
    try std.testing.expect(hasDependency(&deployment.graph, instance.id, address.id));
    try std.testing.expect(hasDependency(&deployment.graph, instance.id, account.id));
    try std.testing.expect(hasDependency(&deployment.graph, instance.id, version.id));
    try std.testing.expect(hasDependency(&deployment.graph, instance.id, access.id));
    try std.testing.expect(hasDependency(&deployment.graph, instance.id, record.id));
    try std.testing.expect(hasDependency(&deployment.graph, record.id, address.id));

    try std.testing.expect(deployment.instance == .resource_ref);
    try std.testing.expect(deployment.public_ip == .resource_ref);
    try std.testing.expect(deployment.desktop_url == .value);
    try std.testing.expectEqualStrings("https://hermes.example.com", deployment.desktop_url.value);
    try std.testing.expect(deployment.network == .resource_ref);
    try std.testing.expect(deployment.subnetwork == .resource_ref);
    try std.testing.expect(deployment.disk == .resource_ref);
    try std.testing.expect(deployment.service_account == .resource_ref);
    try std.testing.expect(deployment.environment_secret == .resource_ref);
    try expectOutputInGraph(&deployment.graph, deployment.network);
    try expectOutputInGraph(&deployment.graph, deployment.subnetwork);
    try expectOutputInGraph(&deployment.graph, deployment.service_account);
    try expectOutputInGraph(&deployment.graph, deployment.environment_secret);
}

test "HermesCompute requires pinned images and its minimum useful capacity" {
    var args = baseArgs();
    args.hermes_image = "nousresearch/hermes-agent:latest";
    try std.testing.expectError(error.UnpinnedHermesImage, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.hermes_image = "nousresearch/hermes-agent";
    try std.testing.expectError(error.UnpinnedHermesImage, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.proxy_image = "caddy:latest";
    try std.testing.expectError(error.UnpinnedHermesProxyImage, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.machine_type = "e2-small";
    try std.testing.expectError(error.UndersizedHermesMachine, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.disk_size_gb = 19;
    try std.testing.expectError(error.UndersizedHermesDisk, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));
}

test "HermesCompute validates regional and secret boundaries" {
    var args = baseArgs();
    args.zone = "us-central1-a";
    try std.testing.expectError(error.HermesRegionZoneMismatch, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.environment_source = .{ .provider = "", .resource = "HERMES_ENV_FILE", .version = "1" };
    try std.testing.expectError(error.InvalidHermesSecretReference, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.domain = "https://hermes.example.com";
    try std.testing.expectError(error.InvalidHermesDesktopDomain, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.oauth_client_id = "client-without-agent-prefix";
    try std.testing.expectError(error.InvalidHermesOauthClientId, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.dns_zone = "invalid zone";
    try std.testing.expectError(error.InvalidHermesDnsZone, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));

    args = baseArgs();
    args.startup_script_sha256 = "not-a-digest";
    try std.testing.expectError(error.InvalidStartupScript, ziac.gcp.HermesCompute.build(std.testing.allocator, provider, args));
}

test "Hermes Compute bootstrap serves Desktop through OAuth-gated TLS" {
    const startup_script = try readScript("scripts/hermes-compute-startup.sh");
    defer std.testing.allocator.free(startup_script);
    try std.testing.expect(std.mem.startsWith(u8, startup_script, "#!/usr/bin/env bash\nset -euo pipefail\n"));
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "Metadata-Flavor: Google") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "secretmanager.googleapis.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "umask 077") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "chmod 0600") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "--publish 127.0.0.1:8642:8642") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "--publish 127.0.0.1:9119:9119") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "HERMES_DASHBOARD=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "HERMES_DASHBOARD_HOST=0.0.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "HERMES_DASHBOARD_PUBLIC_URL=https://") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "HERMES_DASHBOARD_OAUTH_CLIENT_ID=") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "reverse_proxy 127.0.0.1:9119") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "--network host") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "--restart unless-stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "--env-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "0.0.0.0:8642") == null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "0.0.0.0:9119") == null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "docker.sock") == null);
    try std.testing.expect(std.mem.indexOf(u8, startup_script, "set -x") == null);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(startup_script, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(ziac.gcp.hermes_compute.reviewed_startup_script_sha256, &encoded);
}

test "Hermes Compute qualification is fail-closed and probes the Desktop path" {
    const qualification_script = try readScript("scripts/qualify-hermes-compute.sh");
    defer std.testing.allocator.free(qualification_script);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "*-ziac-disposable") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "QUALIFY_DISPOSABLE_HERMES_COMPUTE") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "exit 77") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "application-default print-access-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, startup_digest) != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "--tunnel-through-iap") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "start-iap-tunnel") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "HERMES_DOMAIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "HERMES_DNS_ZONE") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "HERMES_OAUTH_CLIENT_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "https://${HERMES_DOMAIN}/api/status") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "auth_required") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "auth_providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "restart_persistence") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "cleanup:\"empty\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, qualification_script, "cat ${HERMES_ENV_FILE}") == null);
}

fn readScript(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(256 * 1024));
}

fn baseArgs() ziac.gcp.HermesComputeArgs {
    return .{
        .name = "hermes",
        .region = "europe-west1",
        .zone = "europe-west1-b",
        .domain = "hermes.example.com",
        .dns_zone = "example-com",
        .oauth_client_id = "agent:ziac-hermes-test",
        .environment_source = .{ .provider = "env", .resource = "HERMES_ENV_FILE", .version = "1" },
        .startup_script = .known(.{ .provider = "env", .resource = "ZIAC_HERMES_STARTUP_SCRIPT", .version = "1" }),
        .startup_script_sha256 = startup_digest,
    };
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node;
    unreachable;
}

fn findIdContaining(graph: *const ziac.ResourceGraph, type_name: []const u8, needle: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name) and std.mem.indexOf(u8, node.id, needle) != null) return node;
    }
    unreachable;
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}

fn expectOutputInGraph(graph: *const ziac.ResourceGraph, candidate: ziac.PublicOutput([]const u8)) !void {
    const reference = candidate.referenceOrNull() orelse return error.TestExpectedEqual;
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, reference.resource_id)) return;
    return error.TestExpectedEqual;
}

fn input(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    return nestedField(node.inputs, name);
}

fn nestedField(candidate: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (candidate.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn firstListItem(candidate: ziac.value.Value) ziac.value.Value {
    return candidate.list[0];
}

fn expectString(candidate: ziac.value.Value, expected: []const u8) !void {
    try std.testing.expect(candidate == .string);
    try std.testing.expectEqualStrings(expected, candidate.string);
}

fn expectInteger(candidate: ziac.value.Value, expected: i64) !void {
    try std.testing.expect(candidate == .integer);
    try std.testing.expectEqual(expected, candidate.integer);
}

fn expectBoolean(candidate: ziac.value.Value, expected: bool) !void {
    try std.testing.expect(candidate == .boolean);
    try std.testing.expectEqual(expected, candidate.boolean);
}

fn expectOutputReference(candidate: ziac.value.Value, resource_id: []const u8, field: []const u8) !void {
    try std.testing.expect(candidate == .output_ref);
    try std.testing.expectEqualStrings(resource_id, candidate.output_ref.resource_id);
    try std.testing.expectEqualStrings(field, candidate.output_ref.field);
}

fn expectMetadata(instance: ziac.ResourceNode, key: []const u8, expected: []const u8) !void {
    const metadata = input(instance, "metadata");
    for (metadata.list) |entry| {
        const entry_key = nestedField(entry, "key");
        if (entry_key == .string and std.mem.eql(u8, entry_key.string, key)) {
            return expectString(nestedField(entry, "value"), expected);
        }
    }
    return error.TestExpectedEqual;
}

fn containsString(candidate: ziac.value.Value, needle: []const u8) bool {
    return switch (candidate) {
        .string => |text| std.mem.indexOf(u8, text, needle) != null,
        .list => |items| for (items) |item| {
            if (containsString(item, needle)) break true;
        } else false,
        .object => |fields| for (fields) |field| {
            if (containsString(field.value, needle)) break true;
        } else false,
        else => false,
    };
}

fn containsExactString(candidate: ziac.value.Value, expected: []const u8) bool {
    return switch (candidate) {
        .string => |text| std.mem.eql(u8, text, expected),
        .list => |items| for (items) |item| {
            if (containsExactString(item, expected)) break true;
        } else false,
        .object => |fields| for (fields) |field| {
            if (containsExactString(field.value, expected)) break true;
        } else false,
        else => false,
    };
}
