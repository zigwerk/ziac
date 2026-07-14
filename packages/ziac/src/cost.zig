const std = @import("std");

pub const Origin = enum {
    configuration_estimate,
    projected_month_end,
    actual_billed,
};

pub const Confidence = enum {
    explicit_usage,
    billing_partial_month,
    billing_complete,
};

pub const Provenance = struct {
    is_catalog_price: bool = false,
    is_billing_export: bool = false,
    includes_credits: bool = false,
    observed_at_millis: u64,
};

pub const ResourceCost = struct {
    schema: []const u8 = "ziac.resource-cost.v1",
    resource_id: []const u8,
    origin: Origin,
    currency: []const u8 = "USD",
    amount_micros: ?i64,
    confidence: Confidence,
    provenance: Provenance,
};

pub const SkuPrice = struct {
    sku_id: []const u8,
    region: []const u8,
    unit: []const u8,
    unit_quantity: u64,
    unit_price_micros: i64,
    currency: []const u8 = "USD",
    effective_time: ?[]const u8 = null,
    tiers: []const TierRate = &.{},
};

pub const TierRate = struct {
    start_quantity: u64,
    unit_price_micros: i64,
};

pub const UsageAssumption = struct {
    sku_id: []const u8,
    region: []const u8,
    quantity: u64,
};

pub const StorageEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    storage_sku_id: []const u8,
    operations_sku_id: []const u8,
    egress_sku_id: []const u8,
    stored_gib_month: u64,
    operations: u64,
    egress_gib: u64,
    observed_at_millis: u64,
};

pub const PubsubEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    throughput_sku_id: []const u8,
    storage_sku_id: []const u8,
    egress_sku_id: []const u8,
    throughput_gib: u64,
    retained_gib_month: u64,
    egress_gib: u64,
    observed_at_millis: u64,
};

pub const TasksEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    operations_sku_id: []const u8,
    egress_sku_id: []const u8,
    billable_operations: u64,
    egress_gib: u64,
    observed_at_millis: u64,
};

pub const EventarcEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    events_sku_id: []const u8,
    transport_sku_id: []const u8,
    chargeable_events: u64,
    transport_gib: u64,
    observed_at_millis: u64,
};

pub const BigqueryEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    query_sku_id: []const u8,
    storage_sku_id: []const u8,
    slot_sku_id: []const u8,
    query_tib: u64,
    stored_gib_month: u64,
    reserved_slot_hours: u64,
    observed_at_millis: u64,
};

pub const FirestoreEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    read_sku_id: []const u8,
    write_sku_id: []const u8,
    delete_sku_id: []const u8,
    storage_sku_id: []const u8,
    backup_sku_id: []const u8,
    document_reads: u64,
    document_writes: u64,
    document_deletes: u64,
    stored_gib_month: u64,
    backup_gib_month: u64,
    observed_at_millis: u64,
};

pub const CloudSqlEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    cpu_sku_id: []const u8,
    memory_sku_id: []const u8,
    storage_sku_id: []const u8,
    backup_sku_id: []const u8,
    egress_sku_id: []const u8,
    vcpu_hours: u64,
    memory_gib_hours: u64,
    stored_gib_month: u64,
    backup_gib_month: u64,
    egress_gib: u64,
    observed_at_millis: u64,
};

pub const SpannerEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    compute_sku_id: []const u8,
    storage_sku_id: []const u8,
    backup_sku_id: []const u8,
    processing_unit_hours: u64,
    stored_gib_month: u64,
    backup_gib_month: u64,
    observed_at_millis: u64,
};

pub const MemorystoreEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    capacity_sku_id: []const u8,
    egress_sku_id: []const u8,
    capacity_gib_hours: u64,
    egress_gib: u64,
    observed_at_millis: u64,
};

pub const CloudRunJobEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    cpu_sku_id: []const u8,
    memory_sku_id: []const u8,
    gpu_sku_id: []const u8 = "",
    task_count: u64,
    executions_per_month: u64,
    average_task_seconds: u64,
    vcpu_per_task: u64,
    memory_gib_per_task: u64,
    gpu_per_task: u64 = 0,
    observed_at_millis: u64,
};

pub const CloudRunWorkerPoolEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    cpu_sku_id: []const u8,
    memory_sku_id: []const u8,
    gpu_sku_id: []const u8 = "",
    instance_count: u64,
    active_seconds_per_instance: u64,
    vcpu_per_instance: u64,
    memory_gib_per_instance: u64,
    gpu_per_instance: u64 = 0,
    observed_at_millis: u64,
};

pub const ComputeWorkloadEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    cpu_sku_id: []const u8 = "",
    memory_sku_id: []const u8 = "",
    gpu_sku_id: []const u8 = "",
    disk_sku_id: []const u8 = "",
    image_storage_sku_id: []const u8 = "",
    instance_hours: u64 = 0,
    vcpu_per_instance: u64 = 0,
    memory_gib_per_instance: u64 = 0,
    gpu_per_instance: u64 = 0,
    disk_gib_month: u64 = 0,
    image_gib_month: u64 = 0,
    observed_at_millis: u64,
};

pub const NetworkDeliveryEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    forwarding_rule_sku_id: []const u8 = "",
    data_processed_sku_id: []const u8 = "",
    health_probe_sku_id: []const u8 = "",
    forwarding_rule_hours: u64 = 0,
    data_processed_gib: u64 = 0,
    health_probes: u64 = 0,
    observed_at_millis: u64,
};

pub const EdgeSecurityEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8 = "global",
    cache_egress_sku_id: []const u8 = "",
    cache_fill_sku_id: []const u8 = "",
    cache_lookup_sku_id: []const u8 = "",
    armor_request_sku_id: []const u8 = "",
    certificate_sku_id: []const u8 = "",
    cache_egress_gib: u64 = 0,
    cache_fill_gib: u64 = 0,
    cache_lookup_requests: u64 = 0,
    armor_requests: u64 = 0,
    certificate_months: u64 = 0,
    observed_at_millis: u64,
};

pub const ConnectivityEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8 = "global",
    vpn_tunnel_sku_id: []const u8 = "",
    ncc_hybrid_spoke_sku_id: []const u8 = "",
    ncc_vpc_spoke_sku_id: []const u8 = "",
    ncc_data_transfer_sku_id: []const u8 = "",
    vpn_tunnel_hours: u64 = 0,
    ncc_hybrid_spoke_hours: u64 = 0,
    ncc_vpc_spoke_hours: u64 = 0,
    ncc_data_transfer_gib: u64 = 0,
    observed_at_millis: u64,
};

pub const ContainerPlatformEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    gke_management_sku_id: []const u8 = "",
    node_cpu_sku_id: []const u8 = "",
    node_memory_sku_id: []const u8 = "",
    function_invocation_sku_id: []const u8 = "",
    function_cpu_sku_id: []const u8 = "",
    function_memory_sku_id: []const u8 = "",
    batch_cpu_sku_id: []const u8 = "",
    batch_memory_sku_id: []const u8 = "",
    gke_management_hours: u64 = 0,
    node_vcpu_hours: u64 = 0,
    node_memory_gib_hours: u64 = 0,
    function_invocations: u64 = 0,
    function_vcpu_seconds: u64 = 0,
    function_memory_gib_seconds: u64 = 0,
    batch_vcpu_hours: u64 = 0,
    batch_memory_gib_hours: u64 = 0,
    observed_at_millis: u64,
};

pub const MonitoringEstimateInput = struct {
    resource_id: []const u8,
    uptime_execution_sku_id: []const u8 = "",
    alert_metric_reference_sku_id: []const u8 = "",
    uptime_executions: u64 = 0,
    free_uptime_executions: u64 = 0,
    alert_metric_reference_months: u64 = 0,
    observed_at_millis: u64,
};

pub const LoggingEstimateInput = struct {
    resource_id: []const u8,
    normal_ingestion_sku_id: []const u8 = "",
    vended_ingestion_sku_id: []const u8 = "",
    excess_retention_sku_id: []const u8 = "",
    custom_metric_bytes_sku_id: []const u8 = "",
    normal_ingestion_gib: u64 = 0,
    free_normal_ingestion_gib: u64 = 0,
    vended_ingestion_gib: u64 = 0,
    retained_gib_months_beyond_30_days: u64 = 0,
    custom_metric_mib_months: u64 = 0,
    observed_at_millis: u64,
};

pub const BuildDeliveryEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    default_build_minute_sku_id: []const u8 = "",
    private_build_minute_sku_id: []const u8 = "",
    private_disk_sku_id: []const u8 = "",
    artifact_storage_sku_id: []const u8 = "",
    artifact_transfer_sku_id: []const u8 = "",
    vulnerability_scan_sku_id: []const u8 = "",
    default_build_minutes: u64 = 0,
    free_default_build_minutes: u64 = 0,
    private_build_minutes: u64 = 0,
    private_disk_gib_hours: u64 = 0,
    artifact_storage_gib_month: u64 = 0,
    artifact_transfer_gib: u64 = 0,
    vulnerability_scans: u64 = 0,
    observed_at_millis: u64,
};

pub const CloudDeployEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    active_pipeline_sku_id: []const u8 = "",
    underlying_build_minute_sku_id: []const u8 = "",
    active_multi_target_pipelines: u64 = 0,
    free_active_multi_target_pipelines: u64 = 1,
    underlying_build_minutes: u64 = 0,
    observed_at_millis: u64,
};

pub const KmsSecretEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    kms_software_version_sku_id: []const u8 = "",
    kms_hsm_version_sku_id: []const u8 = "",
    kms_external_version_sku_id: []const u8 = "",
    secret_replica_version_sku_id: []const u8 = "",
    secret_access_sku_id: []const u8 = "",
    kms_software_active_versions: u64 = 0,
    kms_hsm_active_versions: u64 = 0,
    kms_external_active_versions: u64 = 0,
    secret_active_replica_versions: u64 = 0,
    secret_access_operations: u64 = 0,
    observed_at_millis: u64,
};

pub const ApplicationServicesEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8 = "global",
    workflow_internal_steps_sku_id: []const u8 = "",
    workflow_external_steps_sku_id: []const u8 = "",
    gateway_calls_sku_id: []const u8 = "",
    identity_tier1_mau_sku_id: []const u8 = "",
    identity_tier2_mau_sku_id: []const u8 = "",
    workflow_internal_steps: u64 = 0,
    workflow_external_steps: u64 = 0,
    gateway_calls: u64 = 0,
    identity_tier1_mau: u64 = 0,
    identity_tier2_mau: u64 = 0,
    observed_at_millis: u64,
};

pub const BillingRow = struct {
    resource_id: []const u8,
    cost_micros: i64,
    credit_micros: i64,
};

pub const AttributionTarget = struct {
    ziac_resource_id: []const u8,
    global_name: []const u8,
};

pub const AttributionResult = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    costs: []ResourceCost,
    currency: []const u8,
    billed_total_micros: i64,
    attributed_total_micros: i64,
    unattributed_total_micros: i64,
    coverage_basis_points: u16,
    observed_at_millis: u64,

    pub fn deinit(self: *AttributionResult) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const CatalogPage = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    prices: []SkuPrice,
    next_page_token: ?[]const u8,

    pub fn deinit(self: *CatalogPage) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn parseCatalogPageAlloc(allocator: std.mem.Allocator, body: []const u8) !CatalogPage {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return error.InvalidCatalogResponse;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.InvalidCatalogResponse;
    const skus = jsonArray(root.get("skus")) orelse return error.InvalidCatalogResponse;
    var prices = std.ArrayList(SkuPrice).empty;
    for (skus.items) |sku_value| {
        const sku = jsonObject(sku_value) orelse return error.InvalidCatalogResponse;
        const sku_id = jsonString(sku.get("skuId")) orelse return error.InvalidCatalogResponse;
        const regions = jsonArray(sku.get("serviceRegions")) orelse return error.InvalidCatalogResponse;
        const infos = jsonArray(sku.get("pricingInfo")) orelse return error.InvalidCatalogResponse;
        if (infos.items.len == 0) continue;
        const info = jsonObject(infos.items[infos.items.len - 1]) orelse return error.InvalidCatalogResponse;
        const expression = jsonObject(info.get("pricingExpression") orelse return error.InvalidCatalogResponse) orelse return error.InvalidCatalogResponse;
        const unit = jsonString(expression.get("usageUnit")) orelse return error.InvalidCatalogResponse;
        const unit_quantity = jsonU64(expression.get("baseUnitConversionFactor")) orelse 1;
        const rates = jsonArray(expression.get("tieredRates")) orelse return error.InvalidCatalogResponse;
        if (rates.items.len == 0) continue;
        const tiers = try a.alloc(TierRate, rates.items.len);
        var currency: []const u8 = "USD";
        for (rates.items, 0..) |rate_value, rate_index| {
            const rate = jsonObject(rate_value) orelse return error.InvalidCatalogResponse;
            const money = jsonObject(rate.get("unitPrice") orelse return error.InvalidCatalogResponse) orelse return error.InvalidCatalogResponse;
            const units_text = jsonString(money.get("units")) orelse "0";
            const units = std.fmt.parseInt(i64, units_text, 10) catch return error.InvalidCatalogResponse;
            const nanos = jsonI64(money.get("nanos")) orelse 0;
            const micros = std.math.mul(i64, units, 1_000_000) catch return error.CostOverflow;
            currency = jsonString(money.get("currencyCode")) orelse currency;
            tiers[rate_index] = .{
                .start_quantity = jsonU64(rate.get("startUsageAmount")) orelse 0,
                .unit_price_micros = micros + @divTrunc(nanos, 1000),
            };
        }
        if (regions.items.len == 0) {
            try prices.append(a, .{
                .sku_id = try a.dupe(u8, sku_id),
                .region = try a.dupe(u8, "global"),
                .unit = try a.dupe(u8, unit),
                .unit_quantity = unit_quantity,
                .unit_price_micros = tiers[0].unit_price_micros,
                .currency = try a.dupe(u8, currency),
                .effective_time = if (jsonString(info.get("effectiveTime"))) |time| try a.dupe(u8, time) else null,
                .tiers = tiers,
            });
        } else for (regions.items) |region_value| {
            const region = switch (region_value) {
                .string => |text| text,
                else => return error.InvalidCatalogResponse,
            };
            try prices.append(a, .{
                .sku_id = try a.dupe(u8, sku_id),
                .region = try a.dupe(u8, region),
                .unit = try a.dupe(u8, unit),
                .unit_quantity = unit_quantity,
                .unit_price_micros = tiers[0].unit_price_micros,
                .currency = try a.dupe(u8, currency),
                .effective_time = if (jsonString(info.get("effectiveTime"))) |time| try a.dupe(u8, time) else null,
                .tiers = tiers,
            });
        }
    }
    const token = if (jsonString(root.get("nextPageToken"))) |value| try a.dupe(u8, value) else null;
    return .{ .allocator = allocator, .arena = arena, .prices = try prices.toOwnedSlice(a), .next_page_token = token };
}

pub fn detailedBillingQueryAlloc(allocator: std.mem.Allocator, normalized_view: []const u8, project_id: []const u8) ![]u8 {
    if (!validSqlIdentity(normalized_view) or !validProjectId(project_id)) return error.InvalidBillingQuery;
    return std.fmt.allocPrint(
        allocator,
        "WITH normalized AS (SELECT COALESCE(resource.global_name, CONCAT('//unattributed.googleapis.com/projects/', project.id, '/skus/', sku.id)) AS resource_id, cost, IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS credits FROM `{s}` WHERE project.id = '{s}' AND usage_start_time >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)) SELECT resource_id, CAST(ROUND(SUM(cost) * 1000000) AS INT64) AS cost_micros, CAST(ROUND(SUM(credits) * 1000000) AS INT64) AS credit_micros FROM normalized GROUP BY resource_id ORDER BY resource_id",
        .{ normalized_view, project_id },
    );
}

pub fn configurationEstimate(
    resource_id: []const u8,
    prices: []const SkuPrice,
    usage: []const UsageAssumption,
    observed_at_millis: u64,
) !ResourceCost {
    try validateIdentity(resource_id, observed_at_millis);
    if (usage.len == 0) return error.PricingUnavailable;
    var total: i128 = 0;
    for (usage) |assumption| {
        const price = findPrice(prices, assumption.sku_id, assumption.region) orelse return error.PricingUnavailable;
        if (price.unit_quantity == 0 or assumption.quantity > std.math.maxInt(i64)) return error.InvalidPricing;
        total += if (price.tiers.len == 0)
            @divTrunc(@as(i128, @intCast(assumption.quantity)) * price.unit_price_micros, price.unit_quantity)
        else
            try tieredCost(price, assumption.quantity);
    }
    const amount = std.math.cast(i64, total) orelse return error.CostOverflow;
    return .{
        .resource_id = resource_id,
        .origin = .configuration_estimate,
        .amount_micros = amount,
        .confidence = .explicit_usage,
        .provenance = .{ .is_catalog_price = true, .observed_at_millis = observed_at_millis },
    };
}

pub fn storageConfigurationEstimate(
    prices: []const SkuPrice,
    input: StorageEstimateInput,
) !ResourceCost {
    var usage: [3]UsageAssumption = undefined;
    var count: usize = 0;
    if (input.stored_gib_month > 0) {
        if (input.storage_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.storage_sku_id, .region = input.region, .quantity = input.stored_gib_month };
        count += 1;
    }
    if (input.operations > 0) {
        if (input.operations_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.operations_sku_id, .region = input.region, .quantity = input.operations };
        count += 1;
    }
    if (input.egress_gib > 0) {
        if (input.egress_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.egress_sku_id, .region = input.region, .quantity = input.egress_gib };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn pubsubConfigurationEstimate(
    prices: []const SkuPrice,
    input: PubsubEstimateInput,
) !ResourceCost {
    var usage: [3]UsageAssumption = undefined;
    var count: usize = 0;
    if (input.throughput_gib > 0) {
        if (input.throughput_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.throughput_sku_id, .region = input.region, .quantity = input.throughput_gib };
        count += 1;
    }
    if (input.retained_gib_month > 0) {
        if (input.storage_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.storage_sku_id, .region = input.region, .quantity = input.retained_gib_month };
        count += 1;
    }
    if (input.egress_gib > 0) {
        if (input.egress_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.egress_sku_id, .region = input.region, .quantity = input.egress_gib };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn tasksConfigurationEstimate(
    prices: []const SkuPrice,
    input: TasksEstimateInput,
) !ResourceCost {
    var usage: [2]UsageAssumption = undefined;
    var count: usize = 0;
    if (input.billable_operations > 0) {
        if (input.operations_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.operations_sku_id, .region = input.region, .quantity = input.billable_operations };
        count += 1;
    }
    if (input.egress_gib > 0) {
        if (input.egress_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.egress_sku_id, .region = input.region, .quantity = input.egress_gib };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn eventarcConfigurationEstimate(
    prices: []const SkuPrice,
    input: EventarcEstimateInput,
) !ResourceCost {
    var usage: [2]UsageAssumption = undefined;
    var count: usize = 0;
    if (input.chargeable_events > 0) {
        if (input.events_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.events_sku_id, .region = input.region, .quantity = input.chargeable_events };
        count += 1;
    }
    if (input.transport_gib > 0) {
        if (input.transport_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.transport_sku_id, .region = input.region, .quantity = input.transport_gib };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn applicationServicesConfigurationEstimate(
    prices: []const SkuPrice,
    input: ApplicationServicesEstimateInput,
) !ResourceCost {
    var usage: [5]UsageAssumption = undefined;
    var count: usize = 0;
    try appendUsage(&usage, &count, input.workflow_internal_steps_sku_id, input.region, input.workflow_internal_steps);
    try appendUsage(&usage, &count, input.workflow_external_steps_sku_id, input.region, input.workflow_external_steps);
    try appendUsage(&usage, &count, input.gateway_calls_sku_id, input.region, input.gateway_calls);
    try appendUsage(&usage, &count, input.identity_tier1_mau_sku_id, input.region, input.identity_tier1_mau);
    try appendUsage(&usage, &count, input.identity_tier2_mau_sku_id, input.region, input.identity_tier2_mau);
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

fn appendUsage(
    usage: []UsageAssumption,
    count: *usize,
    sku_id: []const u8,
    region: []const u8,
    quantity: u64,
) !void {
    if (quantity == 0) return;
    if (sku_id.len == 0 or count.* >= usage.len) return error.InvalidPricing;
    usage[count.*] = .{ .sku_id = sku_id, .region = region, .quantity = quantity };
    count.* += 1;
}

pub fn bigqueryConfigurationEstimate(
    prices: []const SkuPrice,
    input: BigqueryEstimateInput,
) !ResourceCost {
    var usage: [3]UsageAssumption = undefined;
    var count: usize = 0;
    if (input.query_tib > 0) {
        if (input.query_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.query_sku_id, .region = input.region, .quantity = input.query_tib };
        count += 1;
    }
    if (input.stored_gib_month > 0) {
        if (input.storage_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.storage_sku_id, .region = input.region, .quantity = input.stored_gib_month };
        count += 1;
    }
    if (input.reserved_slot_hours > 0) {
        if (input.slot_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.slot_sku_id, .region = input.region, .quantity = input.reserved_slot_hours };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn firestoreConfigurationEstimate(
    prices: []const SkuPrice,
    input: FirestoreEstimateInput,
) !ResourceCost {
    var usage: [5]UsageAssumption = undefined;
    var count: usize = 0;
    const assumptions = [_]struct {
        quantity: u64,
        sku_id: []const u8,
    }{
        .{ .quantity = input.document_reads, .sku_id = input.read_sku_id },
        .{ .quantity = input.document_writes, .sku_id = input.write_sku_id },
        .{ .quantity = input.document_deletes, .sku_id = input.delete_sku_id },
        .{ .quantity = input.stored_gib_month, .sku_id = input.storage_sku_id },
        .{ .quantity = input.backup_gib_month, .sku_id = input.backup_sku_id },
    };
    for (assumptions) |assumption| {
        if (assumption.quantity == 0) continue;
        if (assumption.sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = assumption.sku_id, .region = input.region, .quantity = assumption.quantity };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn cloudSqlConfigurationEstimate(
    prices: []const SkuPrice,
    input: CloudSqlEstimateInput,
) !ResourceCost {
    var usage: [5]UsageAssumption = undefined;
    var count: usize = 0;
    const assumptions = [_]struct {
        quantity: u64,
        sku_id: []const u8,
    }{
        .{ .quantity = input.vcpu_hours, .sku_id = input.cpu_sku_id },
        .{ .quantity = input.memory_gib_hours, .sku_id = input.memory_sku_id },
        .{ .quantity = input.stored_gib_month, .sku_id = input.storage_sku_id },
        .{ .quantity = input.backup_gib_month, .sku_id = input.backup_sku_id },
        .{ .quantity = input.egress_gib, .sku_id = input.egress_sku_id },
    };
    for (assumptions) |assumption| {
        if (assumption.quantity == 0) continue;
        if (assumption.sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = assumption.sku_id, .region = input.region, .quantity = assumption.quantity };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn spannerConfigurationEstimate(
    prices: []const SkuPrice,
    input: SpannerEstimateInput,
) !ResourceCost {
    var usage: [3]UsageAssumption = undefined;
    var count: usize = 0;
    const assumptions = [_]struct { quantity: u64, sku_id: []const u8 }{
        .{ .quantity = input.processing_unit_hours, .sku_id = input.compute_sku_id },
        .{ .quantity = input.stored_gib_month, .sku_id = input.storage_sku_id },
        .{ .quantity = input.backup_gib_month, .sku_id = input.backup_sku_id },
    };
    for (assumptions) |assumption| {
        if (assumption.quantity == 0) continue;
        if (assumption.sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = assumption.sku_id, .region = input.region, .quantity = assumption.quantity };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn memorystoreConfigurationEstimate(
    prices: []const SkuPrice,
    input: MemorystoreEstimateInput,
) !ResourceCost {
    var usage: [2]UsageAssumption = undefined;
    var count: usize = 0;
    if (input.capacity_gib_hours > 0) {
        if (input.capacity_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.capacity_sku_id, .region = input.region, .quantity = input.capacity_gib_hours };
        count += 1;
    }
    if (input.egress_gib > 0) {
        if (input.egress_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{ .sku_id = input.egress_sku_id, .region = input.region, .quantity = input.egress_gib };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn cloudRunJobConfigurationEstimate(
    prices: []const SkuPrice,
    input: CloudRunJobEstimateInput,
) !ResourceCost {
    if (input.task_count == 0 or input.executions_per_month == 0 or input.average_task_seconds == 0 or
        input.vcpu_per_task == 0 or input.memory_gib_per_task == 0)
    {
        return error.InvalidUsageAssumption;
    }
    const task_seconds = try checkedProduct(&.{ input.task_count, input.executions_per_month, input.average_task_seconds });
    return cloudRunComputeEstimate(prices, .{
        .resource_id = input.resource_id,
        .region = input.region,
        .cpu_sku_id = input.cpu_sku_id,
        .memory_sku_id = input.memory_sku_id,
        .gpu_sku_id = input.gpu_sku_id,
        .base_seconds = task_seconds,
        .vcpu = input.vcpu_per_task,
        .memory_gib = input.memory_gib_per_task,
        .gpu = input.gpu_per_task,
        .observed_at_millis = input.observed_at_millis,
    });
}

pub fn cloudRunWorkerPoolConfigurationEstimate(
    prices: []const SkuPrice,
    input: CloudRunWorkerPoolEstimateInput,
) !ResourceCost {
    if (input.instance_count == 0 or input.active_seconds_per_instance == 0 or
        input.vcpu_per_instance == 0 or input.memory_gib_per_instance == 0)
    {
        return error.InvalidUsageAssumption;
    }
    const instance_seconds = try checkedProduct(&.{ input.instance_count, input.active_seconds_per_instance });
    return cloudRunComputeEstimate(prices, .{
        .resource_id = input.resource_id,
        .region = input.region,
        .cpu_sku_id = input.cpu_sku_id,
        .memory_sku_id = input.memory_sku_id,
        .gpu_sku_id = input.gpu_sku_id,
        .base_seconds = instance_seconds,
        .vcpu = input.vcpu_per_instance,
        .memory_gib = input.memory_gib_per_instance,
        .gpu = input.gpu_per_instance,
        .observed_at_millis = input.observed_at_millis,
    });
}

pub fn computeWorkloadConfigurationEstimate(
    prices: []const SkuPrice,
    input: ComputeWorkloadEstimateInput,
) !ResourceCost {
    var usage: [5]UsageAssumption = undefined;
    var count: usize = 0;
    if (input.instance_hours > 0) {
        if (input.vcpu_per_instance == 0 or input.memory_gib_per_instance == 0) return error.InvalidUsageAssumption;
        try appendUsage(&usage, &count, input.cpu_sku_id, input.region, try checkedProduct(&.{ input.instance_hours, input.vcpu_per_instance }));
        try appendUsage(&usage, &count, input.memory_sku_id, input.region, try checkedProduct(&.{ input.instance_hours, input.memory_gib_per_instance }));
        if (input.gpu_per_instance > 0) try appendUsage(&usage, &count, input.gpu_sku_id, input.region, try checkedProduct(&.{ input.instance_hours, input.gpu_per_instance }));
    }
    try appendUsage(&usage, &count, input.disk_sku_id, input.region, input.disk_gib_month);
    try appendUsage(&usage, &count, input.image_storage_sku_id, input.region, input.image_gib_month);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn networkDeliveryConfigurationEstimate(
    prices: []const SkuPrice,
    input: NetworkDeliveryEstimateInput,
) !ResourceCost {
    var usage: [3]UsageAssumption = undefined;
    var count: usize = 0;
    try appendUsage(&usage, &count, input.forwarding_rule_sku_id, input.region, input.forwarding_rule_hours);
    try appendUsage(&usage, &count, input.data_processed_sku_id, input.region, input.data_processed_gib);
    try appendUsage(&usage, &count, input.health_probe_sku_id, input.region, input.health_probes);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn edgeSecurityConfigurationEstimate(prices: []const SkuPrice, input: EdgeSecurityEstimateInput) !ResourceCost {
    var usage: [5]UsageAssumption = undefined;
    var count: usize = 0;
    try appendUsage(&usage, &count, input.cache_egress_sku_id, input.region, input.cache_egress_gib);
    try appendUsage(&usage, &count, input.cache_fill_sku_id, input.region, input.cache_fill_gib);
    try appendUsage(&usage, &count, input.cache_lookup_sku_id, input.region, input.cache_lookup_requests);
    try appendUsage(&usage, &count, input.armor_request_sku_id, input.region, input.armor_requests);
    try appendUsage(&usage, &count, input.certificate_sku_id, input.region, input.certificate_months);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn connectivityConfigurationEstimate(prices: []const SkuPrice, input: ConnectivityEstimateInput) !ResourceCost {
    var usage: [4]UsageAssumption = undefined;
    var count: usize = 0;
    try appendUsage(&usage, &count, input.vpn_tunnel_sku_id, input.region, input.vpn_tunnel_hours);
    try appendUsage(&usage, &count, input.ncc_hybrid_spoke_sku_id, input.region, input.ncc_hybrid_spoke_hours);
    try appendUsage(&usage, &count, input.ncc_vpc_spoke_sku_id, input.region, input.ncc_vpc_spoke_hours);
    try appendUsage(&usage, &count, input.ncc_data_transfer_sku_id, input.region, input.ncc_data_transfer_gib);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn containerPlatformConfigurationEstimate(prices: []const SkuPrice, input: ContainerPlatformEstimateInput) !ResourceCost {
    var usage: [8]UsageAssumption = undefined;
    var count: usize = 0;
    try appendUsage(&usage, &count, input.gke_management_sku_id, "global", input.gke_management_hours);
    try appendUsage(&usage, &count, input.node_cpu_sku_id, input.region, input.node_vcpu_hours);
    try appendUsage(&usage, &count, input.node_memory_sku_id, input.region, input.node_memory_gib_hours);
    try appendUsage(&usage, &count, input.function_invocation_sku_id, input.region, input.function_invocations);
    try appendUsage(&usage, &count, input.function_cpu_sku_id, input.region, input.function_vcpu_seconds);
    try appendUsage(&usage, &count, input.function_memory_sku_id, input.region, input.function_memory_gib_seconds);
    try appendUsage(&usage, &count, input.batch_cpu_sku_id, input.region, input.batch_vcpu_hours);
    try appendUsage(&usage, &count, input.batch_memory_sku_id, input.region, input.batch_memory_gib_hours);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn monitoringConfigurationEstimate(prices: []const SkuPrice, input: MonitoringEstimateInput) !ResourceCost {
    var usage: [2]UsageAssumption = undefined;
    var count: usize = 0;
    const billable_uptime = input.uptime_executions -| input.free_uptime_executions;
    try appendUsage(&usage, &count, input.uptime_execution_sku_id, "global", billable_uptime);
    try appendUsage(&usage, &count, input.alert_metric_reference_sku_id, "global", input.alert_metric_reference_months);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn loggingConfigurationEstimate(prices: []const SkuPrice, input: LoggingEstimateInput) !ResourceCost {
    var usage: [4]UsageAssumption = undefined;
    var count: usize = 0;
    const billable_normal_ingestion = input.normal_ingestion_gib -| input.free_normal_ingestion_gib;
    try appendUsage(&usage, &count, input.normal_ingestion_sku_id, "global", billable_normal_ingestion);
    try appendUsage(&usage, &count, input.vended_ingestion_sku_id, "global", input.vended_ingestion_gib);
    try appendUsage(&usage, &count, input.excess_retention_sku_id, "global", input.retained_gib_months_beyond_30_days);
    try appendUsage(&usage, &count, input.custom_metric_bytes_sku_id, "global", input.custom_metric_mib_months);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn buildDeliveryConfigurationEstimate(prices: []const SkuPrice, input: BuildDeliveryEstimateInput) !ResourceCost {
    var usage: [6]UsageAssumption = undefined;
    var count: usize = 0;
    try appendUsage(&usage, &count, input.default_build_minute_sku_id, input.region, input.default_build_minutes -| input.free_default_build_minutes);
    try appendUsage(&usage, &count, input.private_build_minute_sku_id, input.region, input.private_build_minutes);
    try appendUsage(&usage, &count, input.private_disk_sku_id, input.region, input.private_disk_gib_hours);
    try appendUsage(&usage, &count, input.artifact_storage_sku_id, input.region, input.artifact_storage_gib_month);
    try appendUsage(&usage, &count, input.artifact_transfer_sku_id, input.region, input.artifact_transfer_gib);
    try appendUsage(&usage, &count, input.vulnerability_scan_sku_id, input.region, input.vulnerability_scans);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn cloudDeployConfigurationEstimate(prices: []const SkuPrice, input: CloudDeployEstimateInput) !ResourceCost {
    var usage: [2]UsageAssumption = undefined;
    var count: usize = 0;
    const billable_pipelines = input.active_multi_target_pipelines -| input.free_active_multi_target_pipelines;
    try appendUsage(&usage, &count, input.active_pipeline_sku_id, "global", billable_pipelines);
    try appendUsage(&usage, &count, input.underlying_build_minute_sku_id, input.region, input.underlying_build_minutes);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn kmsSecretConfigurationEstimate(prices: []const SkuPrice, input: KmsSecretEstimateInput) !ResourceCost {
    var usage: [5]UsageAssumption = undefined;
    var count: usize = 0;
    try appendUsage(&usage, &count, input.kms_software_version_sku_id, "global", input.kms_software_active_versions);
    try appendUsage(&usage, &count, input.kms_hsm_version_sku_id, input.region, input.kms_hsm_active_versions);
    try appendUsage(&usage, &count, input.kms_external_version_sku_id, input.region, input.kms_external_active_versions);
    try appendUsage(&usage, &count, input.secret_replica_version_sku_id, "global", input.secret_active_replica_versions);
    try appendUsage(&usage, &count, input.secret_access_sku_id, "global", input.secret_access_operations);
    if (count == 0) return error.InvalidUsageAssumption;
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

pub fn organizationFoundationEstimate(resource_id: []const u8, observed_at_millis: u64) !ResourceCost {
    try validateIdentity(resource_id, observed_at_millis);
    return .{
        .resource_id = resource_id,
        .origin = .configuration_estimate,
        .amount_micros = 0,
        .confidence = .explicit_usage,
        .provenance = .{ .observed_at_millis = observed_at_millis },
    };
}

const CloudRunComputeEstimateInput = struct {
    resource_id: []const u8,
    region: []const u8,
    cpu_sku_id: []const u8,
    memory_sku_id: []const u8,
    gpu_sku_id: []const u8,
    base_seconds: u64,
    vcpu: u64,
    memory_gib: u64,
    gpu: u64,
    observed_at_millis: u64,
};

fn cloudRunComputeEstimate(prices: []const SkuPrice, input: CloudRunComputeEstimateInput) !ResourceCost {
    if (input.cpu_sku_id.len == 0 or input.memory_sku_id.len == 0) return error.InvalidPricing;
    var usage: [3]UsageAssumption = undefined;
    usage[0] = .{
        .sku_id = input.cpu_sku_id,
        .region = input.region,
        .quantity = try checkedProduct(&.{ input.base_seconds, input.vcpu }),
    };
    usage[1] = .{
        .sku_id = input.memory_sku_id,
        .region = input.region,
        .quantity = try checkedProduct(&.{ input.base_seconds, input.memory_gib }),
    };
    var count: usize = 2;
    if (input.gpu > 0) {
        if (input.gpu_sku_id.len == 0) return error.InvalidPricing;
        usage[count] = .{
            .sku_id = input.gpu_sku_id,
            .region = input.region,
            .quantity = try checkedProduct(&.{ input.base_seconds, input.gpu }),
        };
        count += 1;
    }
    return configurationEstimate(input.resource_id, prices, usage[0..count], input.observed_at_millis);
}

fn checkedProduct(factors: []const u64) !u64 {
    var result: u64 = 1;
    for (factors) |factor| result = std.math.mul(u64, result, factor) catch return error.CostOverflow;
    return result;
}

pub fn attributeActualAlloc(
    allocator: std.mem.Allocator,
    rows: []const BillingRow,
    targets: []const AttributionTarget,
    currency: []const u8,
    observed_at_millis: u64,
) !AttributionResult {
    if (currency.len != 3 or observed_at_millis == 0) return error.InvalidCostIdentity;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var billed: i128 = 0;
    for (rows) |row| billed += @as(i128, row.cost_micros) + row.credit_micros;
    var costs = std.ArrayList(ResourceCost).empty;
    var attributed: i128 = 0;
    for (targets) |target| {
        try validateIdentity(target.ziac_resource_id, observed_at_millis);
        var matched = false;
        var amount: i128 = 0;
        for (rows) |row| if (std.mem.eql(u8, row.resource_id, target.global_name)) {
            matched = true;
            amount += @as(i128, row.cost_micros) + row.credit_micros;
        };
        if (!matched) continue;
        const cast_amount = std.math.cast(i64, amount) orelse return error.CostOverflow;
        attributed += amount;
        try costs.append(a, .{
            .resource_id = try a.dupe(u8, target.ziac_resource_id),
            .origin = .actual_billed,
            .currency = try a.dupe(u8, currency),
            .amount_micros = cast_amount,
            .confidence = .billing_complete,
            .provenance = .{ .is_billing_export = true, .includes_credits = true, .observed_at_millis = observed_at_millis },
        });
    }
    const billed_i64 = std.math.cast(i64, billed) orelse return error.CostOverflow;
    const attributed_i64 = std.math.cast(i64, attributed) orelse return error.CostOverflow;
    const coverage: u16 = if (billed == 0)
        0
    else
        @intCast(@min(@as(i128, 10_000), @divTrunc(@abs(attributed) * 10_000, @abs(billed))));
    return .{
        .allocator = allocator,
        .arena = arena,
        .costs = try costs.toOwnedSlice(a),
        .currency = try a.dupe(u8, currency),
        .billed_total_micros = billed_i64,
        .attributed_total_micros = attributed_i64,
        .unattributed_total_micros = std.math.sub(i64, billed_i64, attributed_i64) catch return error.CostOverflow,
        .coverage_basis_points = coverage,
        .observed_at_millis = observed_at_millis,
    };
}

fn tieredCost(price: SkuPrice, quantity: u64) !i128 {
    var total: i128 = 0;
    for (price.tiers, 0..) |tier, index| {
        if (quantity <= tier.start_quantity) break;
        const next = if (index + 1 < price.tiers.len) price.tiers[index + 1].start_quantity else quantity;
        const upper = @min(quantity, next);
        const tier_quantity = upper - tier.start_quantity;
        total += @divTrunc(@as(i128, @intCast(tier_quantity)) * tier.unit_price_micros, price.unit_quantity);
    }
    return total;
}

pub fn actualBilled(resource_id: []const u8, rows: []const BillingRow, observed_at_millis: u64) !ResourceCost {
    try validateIdentity(resource_id, observed_at_millis);
    var matched = false;
    var total: i128 = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.resource_id, resource_id)) continue;
        matched = true;
        total += @as(i128, row.cost_micros) + row.credit_micros;
    }
    if (!matched) return error.BillingDataUnavailable;
    return .{
        .resource_id = resource_id,
        .origin = .actual_billed,
        .amount_micros = std.math.cast(i64, total) orelse return error.CostOverflow,
        .confidence = .billing_complete,
        .provenance = .{
            .is_billing_export = true,
            .includes_credits = true,
            .observed_at_millis = observed_at_millis,
        },
    };
}

pub fn projectMonthEnd(actual: ResourceCost, elapsed_days: u8, month_days: u8, observed_at_millis: u64) !ResourceCost {
    if (actual.origin != .actual_billed or actual.amount_micros == null or elapsed_days == 0 or month_days < elapsed_days or month_days > 31 or observed_at_millis == 0) {
        return error.InvalidProjection;
    }
    const projected = @divTrunc(@as(i128, actual.amount_micros.?) * month_days, elapsed_days);
    return .{
        .resource_id = actual.resource_id,
        .origin = .projected_month_end,
        .currency = actual.currency,
        .amount_micros = std.math.cast(i64, projected) orelse return error.CostOverflow,
        .confidence = .billing_partial_month,
        .provenance = .{
            .is_billing_export = true,
            .includes_credits = actual.provenance.includes_credits,
            .observed_at_millis = observed_at_millis,
        },
    };
}

fn findPrice(prices: []const SkuPrice, sku_id: []const u8, region: []const u8) ?SkuPrice {
    for (prices) |price| {
        if (std.mem.eql(u8, price.sku_id, sku_id) and std.mem.eql(u8, price.region, region)) return price;
    }
    for (prices) |price| {
        if (std.mem.eql(u8, price.sku_id, sku_id) and std.mem.eql(u8, price.region, "global")) return price;
    }
    return null;
}

fn validateIdentity(resource_id: []const u8, observed_at_millis: u64) !void {
    if (resource_id.len == 0 or resource_id.len > 2048 or observed_at_millis == 0 or
        std.mem.indexOfAny(u8, resource_id, "\x00\r\n") != null) return error.InvalidCostIdentity;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}
fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    const present = value orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}
fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}
fn jsonI64(value: ?std.json.Value) ?i64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| number,
        else => null,
    };
}
fn jsonU64(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0 and @floor(number) == number and number <= 9_007_199_254_740_991.0) @intFromFloat(number) else null,
        else => null,
    };
}
fn validSqlIdentity(value: []const u8) bool {
    if (value.len < 5 or value.len > 512) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}
fn validProjectId(value: []const u8) bool {
    if (value.len < 6 or value.len > 63 or !std.ascii.isLower(value[0])) return false;
    for (value) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return value[value.len - 1] != '-';
}
