# Ziac Cloud DNS Record Sets

`gcp.dns.RecordSet` manages one Cloud DNS resource record set in an existing
managed zone. Ziac deliberately treats the zone as an external reference in
this first slice: creating or destroying a record never creates or destroys the
zone.

```zig
var record = try ziac.gcp.dns.RecordSet.build(allocator, gcp, .{
    .zone = "example-com",
    .name = "api.example.com.",
    .record_type = .a,
    .ttl = 60,
    .rrdatas = &.{"203.0.113.10"},
});
```

Record names must be fully qualified and end with a dot. The builder rejects
empty data, duplicate values, invalid TTLs, malformed zone names, and CNAME
sets with anything other than one target.

## Lifecycle And Identity

The provider uses the Cloud DNS `resourceRecordSets` create, get, patch, and
delete methods. TTL and record data update in place. Project, managed zone,
owner name, and record type form the identity and require replacement when
changed.

The physical identifier is stable and importable:

```text
projects/<project>/managedZones/<zone>/rrsets/<type>/<fqdn>
```

Import requires the declaration to name the same project, zone, type, and
fully qualified owner name. This exact-match rule prevents an import from
silently adopting a record outside the declared zone.

The resource emits `fqdn` and `record_type`. The load-balancer component can
wire the global address's typed `address` output directly into
`rrdata_outputs`. Ziac stores the output identity in desired state, derives the
dependency edge automatically, resolves the concrete IP only during provider
execution, and normalizes a matching remote rrset back to the typed reference.
The component therefore does not predict an allocated IP or take ownership of
the parent zone.
