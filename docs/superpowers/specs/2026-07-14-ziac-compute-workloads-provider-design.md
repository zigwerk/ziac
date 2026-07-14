# Ziac M68 Compute Workloads Provider Design

Date: 2026-07-14
Status: accepted for implementation

## Objective

Make Ziac useful for ordinary Compute Engine workloads without weakening its
typed, secret-safe and agent-verifiable provider boundary. M68 adds disks,
images, virtual machines, templates, managed instance groups and autoscalers.
Health checks, firewalls, routes and load-balancing expansion remain M69.

## Resource Surface

M68 manages nine resource types:

1. `gcp.compute.Disk`
2. `gcp.compute.RegionDisk`
3. `gcp.compute.Image`
4. `gcp.compute.Instance`
5. `gcp.compute.InstanceTemplate`
6. `gcp.compute.InstanceGroupManager`
7. `gcp.compute.RegionInstanceGroupManager`
8. `gcp.compute.Autoscaler`
9. `gcp.compute.RegionAutoscaler`

The public declarations live in a focused compute-workloads module and are
re-exported through `ziac.gcp.compute`. The existing compute module remains the
home of networking and global load-balancer primitives.

## Lifecycle Boundary

A dedicated provider handles Compute workload resources. It reuses the Compute
JSON client and operation kernel but adds zonal operation targets. This avoids
making the existing load-balancer adapter responsible for unrelated VM
mutation rules.

- Disks create, read, import and delete by stable zonal/regional identity. Size
  may grow through the native `resize` method; shrinking and source/type/CMEK
  changes require replacement.
- Images and instance templates are immutable artifacts and always replace when
  content changes.
- Instances use explicit disks, network interfaces, service identity, Shielded
  VM and deletion protection. Identity, machine, boot, network and security
  changes conservatively replace the VM. Ziac never embeds SSH keys.
- Managed instance groups update through native PATCH with a current
  fingerprint. Template, rollout policy and target size are visible desired
  state.
- Autoscalers update through native PATCH and keep min/max/target policy
  distinct from the managed group.

All operations checkpoint their global, regional or zonal Compute operation
name and resume through the shared waiter. Physical IDs exactly match Google
resource names under project/global, project/regions or project/zones.

## Secret And Safety Model

Startup scripts are optional typed secret references with a required SHA-256.
The provider resolves them only during instance or template mutation, verifies
the digest before transport, and zeroes the transient body. State, plans,
visual artifacts and logs retain only the reference and digest.

Disks, images, templates and groups are protected and retained by default where
loss or broad replacement is likely. An instance may only auto-delete a boot
disk when the disk is not also declared as an independently retained resource.
Regional disks require two distinct replica zones in their declared region.
Autoscaler bounds and group target size are validated before graph creation.

## Opinionated Components

`VirtualMachine` composes a boot disk and one VM with typed dependency wiring.
It is the small, explicit single-host path.

`ManagedInstanceFleet` composes one immutable template, a zonal or regional MIG
and an autoscaler. The tagged scope prevents accidental mixing of zone and
region identities. Rollout policy and autoscaling are first-class arguments;
M69 health checks can be appended without changing this component contract.

## Product Integration

Permission synthesis derives exact Compute read/create/update/delete, resize,
image use, template use and service-account act-as authority. Cloud Asset
Inventory maps all nine supported asset identities, preserving the documented
regional-disk limitations. Visual artifacts identify VM, disk, image, template,
group and autoscaler topology without rendering startup script bytes.

Configuration cost uses explicit vCPU-hour, memory-GiB-hour, accelerator-hour,
disk-GiB-month and image-storage-GiB-month assumptions. No machine-type lookup
or discount is inferred unless a catalog price and explicit quantity are
provided.

## Qualification

Local qualification applies a fleet, imports it into empty state, refreshes to
no-op and performs retention-aware cleanup with a redacted receipt. The remote
runner requires ADC, a disposable project, explicit zone/region and probe
resource names. It must observe a running VM, ready disk, stable MIG,
acknowledged autoscaler, second-state no-op and cleanup before claiming an
authenticated pass.

## Definition Of Done

M68 is locally complete when declarations, live lifecycle adapters, components,
intelligence, estate, visual metadata, costs, public example, installed docs,
qualification boundary and the full release gate pass. Authenticated status is
claimed only from a disposable-project receipt.
