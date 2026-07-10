const std = @import("std");

test "GitHub preview workflow is keyless reviewed and cleanup guarded" {
    const cwd = std.Io.Dir.cwd();
    const workflow = try cwd.readFileAlloc(
        std.testing.io,
        "examples/github-actions/ziac-preview.yml",
        std.testing.allocator,
        .limited(256 * 1024),
    );
    defer std.testing.allocator.free(workflow);
    const repository_ignore = try cwd.readFileAlloc(
        std.testing.io,
        "../../.gitignore",
        std.testing.allocator,
        .limited(256 * 1024),
    );
    defer std.testing.allocator.free(repository_ignore);
    for ([_][]const u8{
        "id-token: write",
        "contents: read",
        "github.event.pull_request.head.repo.full_name == github.repository",
        "actions/checkout@v7",
        "google-github-actions/auth@v3",
        "actions/upload-artifact@v7",
        "actions/download-artifact@v7",
        "workload_identity_provider:",
        "create_credentials_file: true",
        "environment: ziac-preview-plan",
        "environment: ziac-preview-deploy",
        "environment: ziac-preview-cleanup",
        "preview-stage",
        "ZIAC_STATE_BUCKET",
        "--out",
        "--plan",
        "--approve",
        "--preview-cleanup",
        "--confirm",
        "overwrite: false",
    }) |required| {
        try std.testing.expect(std.mem.indexOf(u8, workflow, required) != null);
    }
    for ([_][]const u8{
        "pull_request_target",
        "credentials_json",
        "private_key",
        "service-account-key",
        "GOOGLE_CREDENTIALS",
    }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, workflow, forbidden) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, repository_ignore, "gha-creds-*.json") != null);
}
