# GCP Compute Workloads

The provider includes a general-purpose Compute Engine workload layer:
persistent disks, regional disks, images, virtual machines, immutable instance
templates, zonal and regional managed instance groups, and zonal and regional
autoscalers. It uses Ziac's three provider layers: typed primitives, hardened
lifecycle adapters, and opinionated components.

## Managed Resources

`Disk` and `RegionDisk` model storage scope, source, CMEK, replica placement,
capacity and retention. Capacity can grow in place through Compute `resize`;
shrinking or changing identity, source or storage class requires replacement.
`Image`, `Instance` and `InstanceTemplate` model immutable boot provenance,
networking, runtime identity, Shielded VM and confidential-compute controls.
Managed groups use Google fingerprints for compare-and-swap patches, and
autoscalers keep replica bounds, CPU target, cooldown and scale-in control
explicit.

Startup scripts are typed secret references with a required SHA-256 digest.
The live provider resolves the reference only while constructing a mutation,
verifies the digest before sending, zeroes the transient payload and preserves
only the reference and digest in state. Canvas artifacts redact the reference
and never contain script bytes.

## Components

- `VirtualMachine` compiles a retained zonal boot disk and a dependent VM. The
  disk is never silently auto-deleted with the instance.
- `ManagedInstanceFleet` uses a tagged zonal or regional scope and compiles one
  immutable template, managed group and autoscaler. Regional zones must belong
  to the declared region, and the initial target must remain within autoscaling
  bounds.

The installed `examples/compute_workloads.zig` demonstrates a regional Zig API
fleet across two zones with a dedicated image, network, service identity,
secret-backed startup script, named port and autoscaling policy.

## GCP Intelligence

Graph synthesis derives `compute.googleapis.com` plus exact permissions for
disks, images, instances, templates, managed groups and autoscalers. Workload
creation also derives image use, disk use, network/subnetwork use and service
account impersonation instead of relying on broad predefined deployer roles.

Cloud Asset discovery maps the Google-supported `Disk`, `Image`, `Instance`,
`InstanceTemplate`, `InstanceGroupManager` and `Autoscaler` identities. The
resource name determines zonal versus regional ownership and is converted to
the same canonical physical ID accepted by import. Existing resources remain
observed until explicitly adopted.

Canvas metadata exposes workload kind, scope, machine type, storage class,
capacity, replica bounds and placement counts. Configuration estimates accept
explicit Catalog SKU IDs and quantities for vCPU-hours, GiB-hours,
accelerator-hours, disk GiB-months and image GiB-months. They are estimates,
not billed or live cost.

## Qualification

The deterministic product gate applies a complete regional fleet, imports it
into empty state, refreshes to no-op, cleans it up and emits
`ziac.gcp.compute-workloads-qualification.v1` evidence.

`scripts/qualify-compute-workloads.sh` is the separate authenticated gate. It
requires ADC, an explicitly disposable project, an end-client workspace and
named probe resources. Missing credentials or configuration produce a
structured exit-77 skip. A passing run proves API reads, second-state no-op
import and destructive cleanup.

## Google Contracts

- [Compute Engine v1 REST](https://cloud.google.com/compute/docs/reference/rest/v1)
- [Regional persistent disks](https://cloud.google.com/compute/docs/disks/regional-persistent-disk)
- [Instance templates](https://cloud.google.com/compute/docs/instance-templates)
- [Managed instance groups](https://cloud.google.com/compute/docs/instance-groups)
- [Autoscaling groups](https://cloud.google.com/compute/docs/autoscaler)
- [Cloud Asset supported types](https://cloud.google.com/asset-inventory/docs/asset-types)
- [Compute Engine pricing](https://cloud.google.com/compute/all-pricing)
