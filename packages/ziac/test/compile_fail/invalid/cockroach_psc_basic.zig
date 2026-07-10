const ziac = @import("ziac");

comptime {
    const Plan = ziac.cockroach.private_service_connect.EligiblePlan;
    if (!@hasField(Plan, "basic")) {
        @compileError("ZIAC132 CockroachDB Basic is not eligible for Ziac Private Service Connect");
    }
    _ = Plan.basic;
}
